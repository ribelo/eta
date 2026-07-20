#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# 2: both-direction par sibling isolation
# 7: daemon retains fork-time capabilities after the lexical scope exits
# 11: an in-flight real Eio sleep ignores a later scoped override
nix develop -c dune exec test/test/test_eta_test.exe -- \
  test '^Scoped capabilities$' '2,7,11' --color=never
