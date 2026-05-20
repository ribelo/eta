#!/usr/bin/env bash
# Bun + TypeScript + Effect reference bench. Emits the same JSON-line
# schema as bench/runtime_overhead/runtime_overhead.exe, so bench/run.sh
# can fold the rows into the result file unchanged.
#
# If `bun` is missing the script prints a notice on stderr and exits 0,
# so the OCaml-side bench is never blocked by an absent JS toolchain.
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"

if ! command -v bun >/dev/null 2>&1; then
  echo "[bench:ts] bun not found on PATH, skipping Bun + Effect bench" >&2
  exit 0
fi

# Resolve effect deps once. `bun install --frozen-lockfile` is fast when the
# lockfile is up to date, and bun stores packages under a global cache so
# repeated runs are cheap.
if [ ! -d "$dir/node_modules/effect" ]; then
  if ! ( cd "$dir" && bun install --frozen-lockfile --silent ) >/dev/null 2>&1; then
    echo "[bench:ts] bun install failed, skipping Bun + Effect bench" >&2
    exit 0
  fi
fi

cd "$dir"
exec bun runtime_overhead.ts "$@"
