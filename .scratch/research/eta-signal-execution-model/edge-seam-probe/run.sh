#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$probe_root" rev-parse --show-toplevel)"
samples="${SAMPLES:-9}"
pairs="${PAIRS:-3}"
cpu="${CPU:-2}"
results="$probe_root/results.csv"
summary="$probe_root/summary.csv"

cd "$repo_root"
if ! git diff --quiet d04d6e2b..HEAD -- lib/signal lib/signal_stream lib/eta; then
  echo "Signal reference sources differ from d04d6e2b" >&2
  exit 1
fi
if ! git diff --quiet -- lib/signal lib/signal_stream lib/eta \
  || ! git diff --cached --quiet -- lib/signal lib/signal_stream lib/eta; then
  echo "Signal reference sources contain dirty changes" >&2
  exit 1
fi

nix develop -c dune build --profile release @install
export OCAMLPATH="$repo_root/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
nix develop -c dune build --root "$probe_root" --profile release \
  probe.exe reference_probe.exe
nix develop -c taskset -c "$cpu" \
  "$probe_root/_build/default/probe.exe" --check

printf 'side,name,pair,operations,sample,wall_ns,allocated_words\n' >"$results"
for pair in $(seq 1 "$pairs"); do
  for workload in observer_failure_retry observer_disposal timer_cycle; do
    PAIR="$pair" nix develop -c taskset -c "$cpu" \
      "$probe_root/_build/default/probe.exe" \
      --measure "$workload" --samples "$samples" |
      tail -n +2 >>"$results"
    PAIR="$pair" nix develop -c taskset -c "$cpu" \
      "$probe_root/_build/default/reference_probe.exe" \
      --measure "$workload" --samples "$samples" |
      tail -n +2 >>"$results"
  done
done

python3 "$probe_root/summarize.py" "$results" >"$summary"
cat "$summary"
