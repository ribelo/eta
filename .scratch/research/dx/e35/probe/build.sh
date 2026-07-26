#!/usr/bin/env bash
set -euo pipefail

probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(git -C "$probe_dir" rev-parse --show-toplevel)
repo_build="$repo_dir/_build-mainline"

# Build the current worktree, not whichever Eta packages happen to be installed
# in the shell. The standalone project then resolves Eta from Dune's generated
# installation tree.
dune build --root "$repo_dir" --build-dir="$repo_build" @install

export OCAMLPATH="$repo_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$probe_dir" --build-dir="$probe_dir/_build" \
  probe_native.exe probe_jsoo.bc.js
