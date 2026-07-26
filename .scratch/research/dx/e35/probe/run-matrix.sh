#!/usr/bin/env bash
# Run the full DX-E35 checkpoint matrix on both backends.
# Each (backend, case, depth) triple runs in a fresh process via run-case.sh.
set -uo pipefail

probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=${1:-"$probe_dir/RESULTS.raw.txt"}
backends=${E35_BACKENDS:-"native byte jsoo"}
export E35_TIMEOUT_SECONDS=${E35_TIMEOUT_SECONDS:-300}

if [[ " $backends " == *" byte "* && -z ${E35_STUB_PATH:-} ]]; then
  E35_STUB_PATH=$(for d in $(ocamlfind printconf path | tr ':' ' '); do
    find "$d" -maxdepth 2 -name 'dll*.so' -printf '%h\n' 2>/dev/null
  done | sort -u | paste -sd: -)
  export E35_STUB_PATH
fi

: > "$out"
for backend in $backends; do
  for case_name in dynamic_bind static_map concat bind_error cause_sequential cause_concurrent; do
    for depth in 10000 100000 1000000; do
      bash "$probe_dir/run-case.sh" "$backend" "$case_name" "$depth" | tee -a "$out"
    done
  done
done
