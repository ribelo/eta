#!/usr/bin/env bash
# Autoresearch regression gate. Exits non-zero if any of:
#   - dune build fails (release profile)
#   - soundness gate rejects a fixture
#   - dune runtest --force fails
#   - watchlist allocation invariants are violated
#       * overhead.eta.bind.100k.prebuilt minor_words must be 0
#       * overhead.eta.pure.reused_rt minor_words must be 0
#       * realuse.retry.flaky.fail4_then_ok minor_words must be 0
#   - watchlist wall-time ceilings are exceeded
#       * pure.reused_rt min wall_ns         <= 8 000 ns
#       * realuse.retry.flaky min wall_ns    <= 80 000 ns
#       * overhead.eta.bind.100k min wall_ns <= 700 000 ns
#
# Ceilings are 1.5-2x v2-ship baseline measured at commit 37ab859 with
# EIO_BACKEND=posix, n=20. They are loose enough to absorb scheduler
# jitter but tight enough to catch real regressions.
#
# The full test suite runs every iteration so unsound performance
# improvements (typed-failure soundness, resource cleanup, supervisor
# semantics, etc.) are rejected before the metric is logged.

set -euo pipefail
cd "$(dirname "$0")"

export EIO_BACKEND="${EIO_BACKEND:-posix}"

echo "[checks] dune build (release) packages/eta/eta.cmxa"
nix develop -c dune build --profile=release packages/eta/eta.cmxa >/dev/null

echo "[checks] soundness gate"
nix develop -c bash packages/eta/test/soundness/run.sh \
  _build/default/packages/eta/eta.cmxa

echo "[checks] dune runtest --force"
nix develop -c dune runtest --force

echo "[checks] watchlist regression bench"
nix develop -c dune build --profile=release \
  bench/runtime_watchlist/runtime_watchlist.exe >/dev/null

JSON="$(_build/default/bench/runtime_watchlist/runtime_watchlist.exe \
  --samples 10)"

python3 - "$JSON" <<'PY'
import json, sys

raw = sys.argv[1]
records = [json.loads(l) for l in raw.splitlines() if l.strip()]
idx = {(r["name"], r["metric"]): r for r in records}

def mean(name, metric):
    return idx[(name, metric)]["mean"]

def minimum(name, metric):
    return idx[(name, metric)]["min"]

violations = []

# Allocation invariants: must be exactly zero.
zero_invariants = [
    ("overhead.eta.bind.100k.prebuilt", "minor_words"),
    ("overhead.eta.pure.reused_rt", "minor_words"),
    ("realuse.retry.flaky.fail4_then_ok", "minor_words"),
]
for name, metric in zero_invariants:
    v = mean(name, metric)
    if v != 0.0:
        violations.append(f"  {name}.{metric} = {v} (must be 0)")

# Wall-time ceilings (min over samples).
ceilings = [
    ("overhead.eta.pure.reused_rt", "wall_ns",       8_000.0),
    ("realuse.retry.flaky.fail4_then_ok", "wall_ns", 80_000.0),
    ("overhead.eta.bind.100k.prebuilt", "wall_ns",   700_000.0),
]
for name, metric, ceiling in ceilings:
    v = minimum(name, metric)
    if v > ceiling:
        violations.append(
            f"  {name}.{metric} min={v:.1f} ns > ceiling {ceiling:.1f} ns"
        )

if violations:
    print("[checks] watchlist regressions detected:")
    for line in violations:
        print(line)
    sys.exit(1)

print("[checks] watchlist OK")
PY
