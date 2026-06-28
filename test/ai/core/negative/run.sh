#!/usr/bin/env bash
set -u

eta_ai_cma="$1"
eta_ai_dir="$(dirname "$eta_ai_cma")"
build_root="$eta_ai_dir/../.."
eta_dir="$build_root/lib/eta"
redacted_dir="$build_root/lib/redacted"
http_dir="$build_root/lib/http"
fixture_dir="$(dirname "$0")"
tmp_dir="${TMPDIR:-/tmp}/eta-ai-negative-$$"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"

  if ocamlfind ocamlc \
      -package "eio,eio_main,threads" \
      -I "$eta_ai_dir/.eta_ai.objs/byte" \
      -I "$eta_dir/.eta.objs/byte" \
      -I "$redacted_dir/.eta_redacted.objs/byte" \
      -I "$http_dir/.eta_http.objs/byte" \
      -I "$http_dir/core/.eta_http_core.objs/byte" \
      -I "$http_dir/body/.eta_http_body.objs/byte" \
      -I "$http_dir/client/.eta_http_client.objs/byte" \
      -I "$http_dir/error/.eta_http_error.objs/byte" \
      -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Fq 'string Eta_redacted.t' "$log" \
      || ! grep -Fq 'expected of type "string"' "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

exit "$status"
