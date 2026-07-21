#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$repo_root"

# The `Run / fiber accounting preserves exit corpus` case executes the same
# success, typed-failure, finalizer, structured-fiber, and race blueprints once
# on an ordinary Eta_eio runtime and once on Run's decorated test contract. It
# compares Exit.t values structurally. The rest of test/test is the unchanged
# Eta_test regression suite around that proof.
nix develop -c dune runtest test/test --force
