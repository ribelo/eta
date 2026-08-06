#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../.." && pwd)"
probe=".scratch/research/eta-signal-execution-model/edge-protocol-probe"
cpu="${CPU:-2}"

cd "$root"
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
export OCAMLPATH="$root/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
nix develop -c dune build --root "$probe" --profile release \
  probe.exe reference_probe.exe
nix develop -c taskset -c "$cpu" "$probe/_build/default/probe.exe" --check

results="$probe/results.csv"
printf 'side,name,pair,operations,sample,wall_ns,allocated_words\n' >"$results"
for pair in 1 2 3; do
  for workload in observer_success observer_failure_retry observer_disposal stream_offer timer_cycle; do
    PAIR="$pair" nix develop -c taskset -c "$cpu" \
      "$probe/_build/default/probe.exe" \
      --measure "$workload" --samples 9 | tail -n +2 >>"$results"
  done
  for workload in observer_failure_retry observer_disposal timer_cycle; do
    PAIR="$pair" nix develop -c taskset -c "$cpu" \
      "$probe/_build/default/reference_probe.exe" \
      --measure "$workload" --samples 9 | tail -n +2 >>"$results"
  done
done

python3 "$probe/summarize.py" "$results" >"$probe/summary.csv"
