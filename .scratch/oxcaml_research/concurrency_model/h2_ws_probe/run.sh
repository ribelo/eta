#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/concurrency_model/h2_ws_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

src="scratch/oxcaml_research/concurrency_model/h2_ws_probe/h2_vs_h3.ml"
exe="$out_dir/h2_vs_h3.exe"
log="$out_dir/h2_vs_h3.log"

packages="portable,portable_ws_deque,parallel,parallel.scheduler,unix"

ocamlfind ocamlopt -extension-universe alpha -package "$packages" -linkpkg "$src" -o "$exe" >"$log" 2>&1
cat "$log" >> "$out_dir/compile.out"
"$exe" | tee "$out_dir/latest.out" | tee -a "$out_dir/compile.out"
rm -f "$exe"
rm -f scratch/oxcaml_research/concurrency_model/h2_ws_probe/h2_vs_h3.cmi
rm -f scratch/oxcaml_research/concurrency_model/h2_ws_probe/h2_vs_h3.cmx
rm -f scratch/oxcaml_research/concurrency_model/h2_ws_probe/h2_vs_h3.o

