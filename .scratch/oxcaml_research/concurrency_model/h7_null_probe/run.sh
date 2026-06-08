#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/concurrency_model/h7_null_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

src="scratch/oxcaml_research/concurrency_model/h7_null_probe/h7_cpu_fanout.ml"
exe="$out_dir/h7_cpu_fanout.exe"
log="$out_dir/h7_cpu_fanout.log"

packages="portable,parallel,parallel.scheduler,unix"

ocamlfind ocamlopt -extension-universe alpha -package "$packages" -linkpkg "$src" -o "$exe" >"$log" 2>&1
cat "$log" >> "$out_dir/compile.out"
"$exe" | tee "$out_dir/latest.out" | tee -a "$out_dir/compile.out"
rm -f "$exe"
rm -f scratch/oxcaml_research/concurrency_model/h7_null_probe/h7_cpu_fanout.cmi
rm -f scratch/oxcaml_research/concurrency_model/h7_null_probe/h7_cpu_fanout.cmx
rm -f scratch/oxcaml_research/concurrency_model/h7_null_probe/h7_cpu_fanout.o
