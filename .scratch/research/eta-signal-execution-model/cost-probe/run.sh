#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$probe_root" rev-parse --show-toplevel)"
samples="${SAMPLES:-3}"
cpu="${CPU:-2}"

cd "$repo_root"
dune build --profile release @install
export OCAMLPATH="$repo_root/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$probe_root" --profile release probe.exe

exe="$probe_root/_build/default/probe.exe"
first=1

for depth in 1 10 100; do
  for layer in \
    raw effect lane public_sync public_eio scheduled_eio observer_eio timer_eio
  do
    if [[ "$first" -eq 1 ]]; then
      taskset -c "$cpu" "$exe" \
        --layer "$layer" --depth "$depth" --samples "$samples"
      first=0
    else
      taskset -c "$cpu" "$exe" \
        --layer "$layer" --depth "$depth" --samples "$samples" |
        tail -n +2
    fi
  done
done
