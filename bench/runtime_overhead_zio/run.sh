#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"

if ! command -v java >/dev/null 2>&1; then
  echo "[bench:zio] java not found on PATH, skipping Scala + ZIO bench" >&2
  exit 0
fi

if ! command -v scala-cli >/dev/null 2>&1; then
  echo "[bench:zio] scala-cli not found on PATH, skipping Scala + ZIO bench" >&2
  exit 0
fi

exec scala-cli --server=false "$dir/RuntimeOverheadZio.scala" -- "$@"
