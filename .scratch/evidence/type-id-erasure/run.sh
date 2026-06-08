#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "=== ocaml version ==="; ocaml -version
for f in 001_services_typeid 002_erased_frame_fails 003_unerased_frame_safe; do
  echo "=== $f ==="
  ocaml "$f.ml"
done
