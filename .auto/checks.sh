#!/usr/bin/env bash
set -euo pipefail

nix develop -c dune build @signal-gates >/dev/null
