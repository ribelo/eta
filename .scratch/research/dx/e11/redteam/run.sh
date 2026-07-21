#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$repo_root"

mkdir -p .scratch/research/dx/e11/redteam .scratch/research/dx/e11/review
daemon_output="$(mktemp)"
broken_output="$(mktemp)"
trap 'rm -f "$daemon_output" "$broken_output"' EXIT

NO_COLOR=1 nix develop -c dune exec test/test/dx_e11_daemon_pending.exe \
  >"$daemon_output" 2>&1

set +e
ALCOTEST_COLOR=never nix develop -c dune exec test/test/dx_e11_broken_retry.exe -- \
  --color=never \
  >"$broken_output" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "broken retry unexpectedly passed" >&2
  exit 1
fi

cp "$daemon_output" .scratch/research/dx/e11/redteam/daemon-output.txt
sed -e '/^warning: Git tree /d' -e '/This run has ID/d' "$broken_output" \
  >.scratch/research/dx/e11/review/broken-output.txt
cp .scratch/research/dx/e11/review/broken-output.txt \
  .scratch/research/dx/e11/redteam/broken-output.txt
