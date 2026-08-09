#!/usr/bin/env bash
set -euo pipefail

bundle_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$bundle_dir/../../.." && pwd)"
switch_dir="${ETA_CRUX_BONSAI_SWITCH:-$repo_dir/.scratch/eta-crux-bonsai-switch}"

eval "$(opam env --switch "$switch_dir" --set-switch)"
export EIO_BACKEND="${EIO_BACKEND:-posix}"
export OCAMLRUNPARAM=""

exec python3 "$bundle_dir/run.py" "$@"
