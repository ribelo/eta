#!/usr/bin/env bash
set -euo pipefail

ROOT="${DUNE_SOURCEROOT:-$(cd "$(dirname "$0")/../../../../.." && pwd)}"
WORK="$ROOT/test/e12_manifest_work"
OUT="$ROOT/.scratch/research/dx/e12/manifest/examples.golden"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ROOT"/examples/*.ml "$ROOT/examples/dune" "$WORK/"

python3 - "$WORK" <<'PY'
from pathlib import Path
import sys

work = Path(sys.argv[1])
base_injection = r'''
module E12_eta_runtime = Eta.Runtime

module E12_capture = struct
  let emit eff =
    let audit = Effect.audit eff in
    let names =
      audit.names |> List.map (Printf.sprintf "%S") |> String.concat ","
    in
    match Sys.getenv_opt "E12_AUDIT_OUT" with
    | None -> failwith "E12_AUDIT_OUT is required"
    | Some path ->
        let out =
          open_out_gen [ Open_creat; Open_append; Open_text ] 0o644 path
        in
        Printf.fprintf out
          "names=[%s] clock=%b logs=%b metrics=%b concurrency=%b resources=%b background=%b\n%!"
          names audit.uses_clock audit.emits_logs audit.emits_metrics
          audit.has_concurrency audit.has_resources audit.has_background;
        close_out out
end

module Runtime = struct
  include E12_eta_runtime
  let run runtime eff =
    E12_capture.emit eff;
    E12_eta_runtime.run runtime eff
end

module Eta = struct
  include Eta
  module Runtime = Runtime
end
'''

eio_injection = r'''
module E12_eta_eio_runtime = Eta_eio.Runtime
module Eta_eio = struct
  include Eta_eio
  module Runtime = struct
    include E12_eta_eio_runtime
    let run runtime eff =
      E12_capture.emit eff;
      E12_eta_eio_runtime.run runtime eff
  end
end
'''

for path in sorted(work.glob("*.ml")):
    source = path.read_text()
    source = source.replace("Eta.Runtime.run", "Runtime.run")
    marker = "open Eta\n"
    if marker not in source:
        raise SystemExit(f"{path.name}: missing {marker!r}")
    injection = base_injection
    if "Eta_eio" in source:
        injection += eio_injection
    path.write_text(source.replace(marker, marker + injection, 1))
PY

cd "$ROOT"
dune build @test/e12_manifest_work/examples

tmp="$(mktemp)"
trap 'rm -f "$tmp"; cleanup' EXIT
: > "$tmp"

count=0
for source in "$ROOT"/examples/*.ml; do
  name="$(basename "$source" .ml)"
  count=$((count + 1))
  printf '===== %s.ml =====\n' "$name" >> "$tmp"
  run_output="$(mktemp)"
  run_audit="$(mktemp)"
  set +e
  E12_AUDIT_OUT="$run_audit" \
    timeout 20s "$ROOT/_build/default/test/e12_manifest_work/$name.exe" \
    > "$run_output" 2>&1
  status=$?
  set -e
  if [[ $status -eq 124 ]]; then
    echo "$name.ml: timed out while regenerating manifest" >&2
    rm -f "$run_output" "$run_audit"
    exit 1
  fi
  if [[ $status -ne 0 ]]; then
    echo "$name.ml: exited with status $status while regenerating manifest" >&2
    cat "$run_output" >&2
    rm -f "$run_output" "$run_audit"
    exit 1
  fi
  if [[ -s "$run_audit" ]]; then
    sed 's/^/run: /' "$run_audit" >> "$tmp"
  else
    printf 'run: <no Effect.t runtime boundary>\n' >> "$tmp"
  fi
  rm -f "$run_output" "$run_audit"
done

if [[ $count -ne 54 ]]; then
  echo "expected 54 examples, found $count" >&2
  exit 1
fi

mv "$tmp" "$OUT"
