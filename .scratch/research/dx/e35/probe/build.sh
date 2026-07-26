#!/usr/bin/env bash
set -euo pipefail

probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(git -C "$probe_dir" rev-parse --show-toplevel)

# Build the current worktree, not whichever Eta packages happen to be installed
# in the shell. The standalone project then resolves Eta from Dune's generated
# installation tree. The OxCaml 5.2.0+ox compiler cannot build js_of_ocaml
# targets (mirroring the repository's own enabled_if guards).
if [[ $(ocamlc -version) == 5.2.0+ox ]]; then
  repo_build="$repo_dir/_build"
  probe_build="$probe_dir/_build-ox"
  targets="probe_native.exe probe_native.bc probe_calibrate.exe"
else
  repo_build="$repo_dir/_build-mainline"
  probe_build="$probe_dir/_build"
  targets="probe_native.exe probe_native.bc probe_jsoo.bc.js probe_calibrate.exe probe_calibrate_js.bc.js"
fi

dune build --root "$repo_dir" --build-dir="$repo_build" @install

export OCAMLPATH="$repo_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$probe_dir" --build-dir="$probe_build" $targets
