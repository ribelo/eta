#!/usr/bin/env bash
# Drives the watchlist regression bench and emits METRIC lines for the
# autoresearch loop. Lower is better on every metric.
#
# Primary metric (composite watchlist_score) combines the four locked rows
# normalized against the v2-ship baseline so each contribution starts ~1.0.
# Lower means a per-row improvement; the loop drives this number down while
# autoresearch.checks.sh enforces the hard zero-allocation invariants.

set -euo pipefail
cd "$(dirname "$0")"

export EIO_BACKEND="${EIO_BACKEND:-posix}"
SAMPLES="${ETA_WATCHLIST_SAMPLES:-20}"

# Build silently. Any build failure is a hard fail (autoresearch will
# log a crash and revert).
nix develop -c dune build --profile=release \
  bench/runtime_watchlist/runtime_watchlist.exe >/dev/null 2>&1

JSON="$(_build/default/bench/runtime_watchlist/runtime_watchlist.exe \
  --samples "$SAMPLES")"

# Parse JSON with python (always available in the repo's nix shell).
python3 - "$JSON" <<'PY'
import json, sys, math

raw = sys.argv[1]
records = []
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    records.append(json.loads(line))

# Index: { (name, metric) : record }
idx = {(r["name"], r["metric"]): r for r in records}

def mean(name, metric):
    return idx[(name, metric)]["mean"]

def minimum(name, metric):
    return idx[(name, metric)]["min"]

# Hard allocation invariants. These MUST stay zero on the watchlist rows.
bind_minor       = mean("overhead.eta.bind.100k.prebuilt", "minor_words")
pure_minor       = mean("overhead.eta.pure.reused_rt", "minor_words")
retry_minor      = mean("realuse.retry.flaky.fail4_then_ok", "minor_words")

# Optimization targets.
fail_catch_minor = mean("overhead.eta.fail_catch.100k.prebuilt", "minor_words")
fail_catch_major = mean("overhead.eta.fail_catch.100k.prebuilt", "major_words")

# Wall-time signals (use min over samples to dampen scheduler noise).
pure_min_ns      = minimum("overhead.eta.pure.reused_rt", "wall_ns")
bind_min_ns      = minimum("overhead.eta.bind.100k.prebuilt", "wall_ns")
fail_catch_min_ns = minimum("overhead.eta.fail_catch.100k.prebuilt", "wall_ns")
retry_min_ns     = minimum("realuse.retry.flaky.fail4_then_ok", "wall_ns")

# v2-ship baselines (commit 37ab859, EIO_BACKEND=posix, n=20). Each
# component contributes 1.0 at baseline so the score starts near 4.0 and
# any improvement drives it down.
BASELINE_FAIL_CATCH_MINOR = 6_291_435.0
BASELINE_PURE_MIN_NS      = 2000.0  # v2 mean ~2229 ns; when below timer floor min=0, score ~0
                                  # floor (samples include 0 ns); use a
                                  # 1 ns floor and divide by it.
BASELINE_BIND_MIN_NS      = 344_991.0
BASELINE_RETRY_MIN_NS     = 29_087.0

# Pure score uses min-ns, but with a positive floor so a sub-ns reading
# still produces a well-defined number (and never blows the score up).
def safe_ratio(value, baseline):
    if baseline <= 0.0:
        return 1.0
    return value / baseline

score = (
    safe_ratio(fail_catch_minor, BASELINE_FAIL_CATCH_MINOR)
    + safe_ratio(max(pure_min_ns, 0.0), max(BASELINE_PURE_MIN_NS, 1.0))
    + safe_ratio(bind_min_ns, BASELINE_BIND_MIN_NS)
    + safe_ratio(retry_min_ns, BASELINE_RETRY_MIN_NS)
)

# Hard invariant signals. autoresearch.checks.sh is the official gate;
# we surface them as metrics too so dashboards can see violations.
def emit(name, value):
    if value is None or (isinstance(value, float) and math.isnan(value)):
        value = 0.0
    if isinstance(value, float):
        print(f"METRIC {name}={value:.6f}")
    else:
        print(f"METRIC {name}={value}")

emit("watchlist_score", score)
emit("fail_catch_minor", fail_catch_minor)
emit("fail_catch_major", fail_catch_major)
emit("fail_catch_min_ns", fail_catch_min_ns)
emit("pure_reused_rt_min_ns", pure_min_ns)
emit("bind_min_ns", bind_min_ns)
emit("retry_min_ns", retry_min_ns)
# Allocation invariants — must remain zero. Surfaced as metrics for visibility.
emit("bind_minor_invariant", bind_minor)
emit("pure_minor_invariant", pure_minor)
emit("retry_minor_invariant", retry_minor)
PY
