#!/usr/bin/env bash
# Autoresearch benchmark for Eta HTTP client performance.
#
# Runs the perf_compare suite in "quick mode" (small iter count, short
# timeout) so each loop iteration is < ~60s, then emits structured
# METRIC lines summarising Eta's median latency vs the reference clients.
#
# Primary metric: eta_total_ms — sum of Eta median latency (ms) across
# all 4 scenarios. Timed-out scenarios contribute the timeout cap. Lower
# is better.
#
# Secondary metrics: per-scenario Eta median, Go median (sanity), and
# eta_errors (count of scenarios where Eta failed).

set -euo pipefail

cd "$(dirname "$0")"

# Loop parameters — sized so each iteration stays under ~60s even when
# H2 currently times out on every sample. Bump ETA_PERF_ITERS once
# behaviour is correct and you want tighter medians.
export ETA_PERF_ITERS="${ETA_PERF_ITERS:-15}"
export ETA_PERF_WARMUP="${ETA_PERF_WARMUP:-3}"
export ETA_PERF_TIMEOUT_MS="${ETA_PERF_TIMEOUT_MS:-500}"

# Fast pre-check: build first so syntax / type errors fail fast (<5s when
# cached) before we pay for server startup.
nix develop -c dune build --profile release \
  http-testsuite/test/perf_compare/run.exe >/dev/null 2>&1

# Run the benchmark. Capture stdout to discover the results dir.
log=$(mktemp)
trap 'rm -f "$log"' EXIT

if ! nix develop -c dune exec --profile release --no-build \
  http-testsuite/test/perf_compare/run.exe > "$log" 2>&1; then
  echo "perf_compare exited non-zero" >&2
  tail -40 "$log" >&2
  exit 1
fi

results_dir=$(grep -oE 'results_dir=[^ ]+' "$log" | head -n1 | cut -d= -f2)
json="$results_dir/perf_compare.json"

if [[ ! -f "$json" ]]; then
  echo "missing results json: $json" >&2
  tail -40 "$log" >&2
  exit 1
fi

# Use jq to compute medians per scenario per client. Treat Eta errors as
# the timeout cap so the metric stays comparable across runs.
timeout_ns=$(( ETA_PERF_TIMEOUT_MS * 1000000 ))

python3 - "$json" "$timeout_ns" <<'PY'
import json, sys

path, timeout_ns = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    rows = json.load(f)

# Group by scenario id, then client.
by_scn = {}
for r in rows:
    by_scn.setdefault(r["scenario"], {})[r["client"]] = r

scenarios = list(by_scn.keys())  # preserve order
eta_total_ns = 0
eta_errors = 0
go_total_ns = 0
metrics = []

for scn in scenarios:
    eta = by_scn[scn].get("eta_warm", {})
    go = by_scn[scn].get("go_warm", {})
    short = (
        scn.replace("nginx_", "")
           .replace("caddy_", "")
           .replace("plain_", "")
           .replace("tls_", "")
    )
    if eta.get("error"):
        eta_med_ns = timeout_ns
        eta_errors += 1
    else:
        eta_med_ns = int(eta.get("median_ns", 0))
    eta_total_ns += eta_med_ns
    metrics.append((f"eta_{short}_ms", eta_med_ns / 1e6))

    if not go.get("error"):
        go_med_ns = int(go.get("median_ns", 0))
        go_total_ns += go_med_ns
        metrics.append((f"go_{short}_ms", go_med_ns / 1e6))

print(f"METRIC eta_total_ms={eta_total_ns / 1e6:.3f}")
print(f"METRIC eta_errors={eta_errors}")
print(f"METRIC go_total_ms={go_total_ns / 1e6:.3f}")
for name, val in metrics:
    print(f"METRIC {name}={val:.3f}")
PY
