#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$root"

probe_dir="scratch/oxcaml_research/concurrency_model/h3_caveats/c3_supervisor_order"
out_dir="$probe_dir/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

src="$probe_dir/portable_task_index_order_positive.ml"
exe="$out_dir/portable_task_index_order_positive.exe"
log="$out_dir/portable_task_index_order_positive.log"

echo "== portable_task_index_order_positive (pass) ==" | tee -a "$out_dir/compile.out"
ocamlfind ocamlopt -extension-universe alpha \
  -package portable,parallel,parallel.scheduler \
  -linkpkg \
  "$src" -o "$exe" >"$log" 2>&1
cat "$log" >> "$out_dir/compile.out"
"$exe" | tee "$out_dir/portable_task_index_order_positive.out" | tee -a "$out_dir/compile.out"
rm -f "$exe" "$probe_dir/portable_task_index_order_positive.cmi" \
  "$probe_dir/portable_task_index_order_positive.cmx" \
  "$probe_dir/portable_task_index_order_positive.o"
echo "summary: pass=1 fail=0" | tee -a "$out_dir/compile.out"
