#!/usr/bin/env bash
# Binary-search the first failing depth for one (backend, case) pair.
# usage: bisect.sh BACKEND CASE LO HI
#   LO must be a known PASS depth, HI a known FAIL depth.
# Prints every probe run and a final BOUNDARY line:
#   max_pass = largest passing depth found, first_fail = smallest failing depth.
set -uo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 BACKEND CASE LO(pass) HI(fail)" >&2
  exit 64
fi

probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backend=$1
case_name=$2
lo=$3
hi=$4
export E35_TIMEOUT_SECONDS=${E35_TIMEOUT_SECONDS:-300}

while (( hi - lo > 1 )); do
  mid=$(( (lo + hi) / 2 ))
  line=$(bash "$probe_dir/run-case.sh" "$backend" "$case_name" "$mid")
  echo "$line"
  if [[ $line == *"status=PASS"* ]]; then
    lo=$mid
  else
    hi=$mid
  fi
done
echo "BOUNDARY backend=$backend case=$case_name max_pass=$lo first_fail=$hi"
