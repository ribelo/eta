#!/usr/bin/env bash
# Drives the OCaml-vs-OxCaml perf comparison from one command.
#
#   bash scratch/oxcaml_research/perf/run_both.sh [-n RUNS] [-q]
#
# For each toolchain (mainline + oxcaml) it runs the OCaml runtime bench
# suite RUNS times, writes one JSON per run under scratch/oxcaml_research/perf/,
# then prints the cross-toolchain comparison.  Default RUNS=2.
#
# Both shells are entered through the flake (`nix develop` and
# `nix develop .#oxcaml`).  EIO_BACKEND=posix is forced so the nix sandbox
# can run the eio-backed benches on either toolchain.
set -euo pipefail

cd "$(dirname "$0")/../../.."

runs=2
quick=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) runs="$2"; shift 2 ;;
    -q|--quick) quick=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

perf_dir="scratch/oxcaml_research/perf"
mkdir -p "$perf_dir"

# Drop stale runs so compare.py sees only the new sample set.
rm -f "$perf_dir"/mainline.*.json "$perf_dir"/oxcaml.*.json

run_one() {
  local shell="$1" label="$2" id="$3"
  local quick_env=""
  if [ "$quick" = "true" ]; then quick_env="QUICK=true"; fi
  echo "== $label run $id (nix develop $shell) =="
  nix develop "$shell" -c bash -lc \
    "EIO_BACKEND=posix $quick_env bash $perf_dir/run_perf.sh $label $id"
}

for i in $(seq 1 "$runs"); do
  run_one ""        mainline "$i"
done
for i in $(seq 1 "$runs"); do
  run_one ".#oxcaml" oxcaml   "$i"
done

python3 "$perf_dir/compare.py" | tee "$perf_dir/compare.txt"
