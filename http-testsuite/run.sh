#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

RUN_INTEROP=true
RUN_CVE=true
RUN_BENCH=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-interop) RUN_INTEROP=false; shift ;;
    --no-cve) RUN_CVE=false; shift ;;
    --no-bench) RUN_BENCH=false; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

INTEROP_STATUS="skipped"
CVE_STATUS="skipped"
BENCH_STATUS="skipped"

if [[ "$RUN_INTEROP" == true ]]; then
  echo "=== Running interop suite ==="
  if dune build @interop --force; then
    INTEROP_STATUS="ok"
  else
    INTEROP_STATUS="FAILED"
  fi
fi

if [[ "$RUN_CVE" == true ]]; then
  echo "=== Running CVE / adversarial suite ==="
  if dune build @cve-regress --force; then
    CVE_STATUS="ok"
  else
    CVE_STATUS="FAILED"
  fi
fi

if [[ "$RUN_BENCH" == true ]]; then
  echo "=== Running benchmark suite ==="
  if dune build @http-bench --force; then
    BENCH_STATUS="ok"
  else
    BENCH_STATUS="FAILED"
  fi
fi

echo ""
echo "Summary: interop=$INTEROP_STATUS cve=$CVE_STATUS bench=$BENCH_STATUS"
echo "Results are in http-testsuite/results/"
ls -td http-testsuite/results/* 2>/dev/null | head -3 || true

if [[ "$INTEROP_STATUS" == "FAILED" || "$CVE_STATUS" == "FAILED" || "$BENCH_STATUS" == "FAILED" ]]; then
  exit 1
fi
