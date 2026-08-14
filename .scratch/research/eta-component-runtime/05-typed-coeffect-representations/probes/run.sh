#!/usr/bin/env bash
set -u

root=$(cd "$(dirname "$0")/../../../../.." && pwd)
probe_dir="$root/.scratch/research/eta-component-runtime/05-typed-coeffect-representations/probes"
result_dir="$root/.scratch/research/eta-component-runtime/05-typed-coeffect-representations/results"

mkdir -p "$result_dir"
ocamlc -version >"$result_dir/toolchain.txt"

run_probe() {
  name=$1
  source=$2
  expected=$3
  {
    printf '$ ocamlc -c %s\n' "$source"
    if ocamlc -c "$probe_dir/$source"; then
      status=0
    else
      status=$?
    fi
    printf 'exit: %d\n' "$status"
    printf 'expected exit: %d\n' "$expected"
    rm -f "$probe_dir/${source%.ml}.cmi" "$probe_dir/${source%.ml}.cmo"
  } >"$result_dir/$name.txt" 2>&1

  if [ "$status" -ne "$expected" ]; then
    printf 'probe %s: expected exit %d, got %d\n' \
      "$name" "$expected" "$status" >&2
    failed=1
  fi
}

failed=0
run_probe type_id_value_restriction type_id_value_restriction.ml 2
run_probe type_id_annotated type_id_annotated.ml 0
run_probe portability_type_id portability_type_id.ml 0
run_probe portability_object portability_object.ml 2
run_probe portability_package portability_package.ml 2
exit "$failed"
