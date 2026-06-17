#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/$STAMP"

cd "$ROOT"
mkdir -p "$RESULT_DIR"

nix develop -c dune exec http-testsuite/test/server_load/run.exe -- \
  --quick --references --h2-only --out "$RESULT_DIR"

python - "$RESULT_DIR/server_load.json" <<'PY'
import json
import math
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open() as f:
    data = json.load(f)

def p99_us(row):
    return float(row["latency_seconds"]["p99"]) * 1_000_000.0

def rps(row):
    return float(row["summary"]["requests_per_sec"])

expected_repeats = int(data.get("config", {}).get("repeats", 3))

def selected_rows(server, transport, endpoint):
    return [
        row
        for row in data["results"]
        if row["server"] == server
        and row["protocol"] == "h2"
        and row["transport"] == transport
        and row["endpoint"] == endpoint
        and int(row["concurrency"]) == 16
        and int(row["connections"]) == 16
        and int(row["streams_per_connection"]) == 1
    ]

def median(values):
    if not values:
        raise SystemExit("missing rows in H2 16x1 benchmark output")
    return statistics.median(values)

def stats(server, transport, endpoint):
    selected = [
        row
        for row in selected_rows(server, transport, endpoint)
        if row.get("status") == "pass"
    ]
    return {
        "p99": median([p99_us(row) for row in selected]),
        "rps": median([rps(row) for row in selected]),
        "p99_repeats": [p99_us(row) for row in selected],
    }

cases = [
    ("tls_root", "tls", "root", "go"),
    ("tls_user_id", "tls", "user_id", "go"),
    ("tls_post_user", "tls", "post_user", "go"),
    ("tls_static_1k", "tls", "static_1k", "go"),
    ("tls_echo_1k", "tls", "echo_1k", "go"),
    ("plain_echo_1k", "plain", "echo_1k", "node"),
]

def selected_failed_count(server, transport, endpoint):
    selected = selected_rows(server, transport, endpoint)
    missing = max(0, expected_repeats - len(selected))
    failed = sum(1 for row in selected if row.get("status") != "pass")
    return missing + failed

failed = 0
ratios = []
rps_ratios = []
tls_ratios = []
tls_rps_ratios = []
eta_p99s = []

for name, transport, endpoint, reference in cases:
    failed += selected_failed_count("eta", transport, endpoint)
    failed += selected_failed_count(reference, transport, endpoint)
    eta = stats("eta", transport, endpoint)
    ref = stats(reference, transport, endpoint)
    ratio = eta["p99"] / ref["p99"]
    rps_ratio = eta["rps"] / ref["rps"]
    ratios.append(ratio)
    rps_ratios.append(rps_ratio)
    if transport == "tls":
        tls_ratios.append(ratio)
        tls_rps_ratios.append(rps_ratio)
    eta_p99s.append(eta["p99"])
    print(f"METRIC h2_16x1_{name}_eta_ref_p99_ratio={ratio:.9g}")
    print(f"METRIC h2_16x1_{name}_eta_ref_rps_ratio={rps_ratio:.9g}")
    print(f"METRIC h2_16x1_{name}_eta_p99_us={eta['p99']:.9g}")
    print(f"METRIC h2_16x1_{name}_ref_p99_us={ref['p99']:.9g}")

geomean = math.exp(sum(math.log(value) for value in ratios) / len(ratios))
rps_geomean = math.exp(
    sum(math.log(value) for value in rps_ratios) / len(rps_ratios)
)
tls_geomean = math.exp(
    sum(math.log(value) for value in tls_ratios) / len(tls_ratios)
)
tls_rps_geomean = math.exp(
    sum(math.log(value) for value in tls_rps_ratios) / len(tls_rps_ratios)
)
finite = all(
    math.isfinite(value)
    for value in ratios + rps_ratios + tls_ratios + tls_rps_ratios
)
success = 1 if failed == 0 and finite else 0

print(f"METRIC h2_16x1_eta_ref_p99_ratio_geomean={geomean:.9g}")
print(f"METRIC h2_16x1_eta_ref_rps_ratio_geomean={rps_geomean:.9g}")
print(f"METRIC h2_16x1_tls_eta_go_p99_ratio_geomean={tls_geomean:.9g}")
print(f"METRIC h2_16x1_tls_eta_go_rps_ratio_geomean={tls_rps_geomean:.9g}")
print(f"METRIC h2_16x1_eta_p99_us_max={max(eta_p99s):.9g}")
print(f"METRIC h2_16x1_failed_results={failed}")
print(f"METRIC h2_16x1_success={success}")
raise SystemExit(0 if success == 1 else 1)
PY
