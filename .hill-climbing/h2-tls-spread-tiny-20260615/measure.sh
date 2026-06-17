#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/$STAMP"
SERVER_LOAD_DIR="$RESULT_DIR/server-load"

cd "$ROOT"
mkdir -p "$RESULT_DIR"

nix develop -c dune exec http-testsuite/test/server_load/run.exe -- \
  --quick --references --h2-only --out "$SERVER_LOAD_DIR" >&2

python3 - "$SERVER_LOAD_DIR/server_load.json" <<'PY'
import json
import math
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1])
raw = json.loads(path.read_text())
rows = [row for row in raw["results"] if row.get("status") == "pass"]

SHAPE = {
    "protocol": "h2",
    "transport": "tls",
    "concurrency": 16,
    "connections": 16,
    "streams_per_connection": 1,
}
DYNAMIC_ENDPOINTS = ["root", "user_id", "post_user"]
GUARD_ENDPOINTS = ["static_1k", "echo_1k"]

def median(values):
    return statistics.median(values)

def geomean(values):
    if any(value <= 0 for value in values):
        return 0.0
    return math.exp(sum(math.log(value) for value in values) / len(values))

def matches_shape(row):
    return all(row.get(name) == value for name, value in SHAPE.items())

def endpoint_rows(server, endpoint):
    return [
        row for row in rows
        if row.get("server") == server
        and row.get("endpoint") == endpoint
        and matches_shape(row)
    ]

def endpoint_p99_us(server, endpoint):
    selected = endpoint_rows(server, endpoint)
    if not selected:
        raise SystemExit(f"missing rows for {server} {endpoint}")
    return median([row["latency_seconds"]["p99"] * 1_000_000.0 for row in selected])

def endpoint_rps(server, endpoint):
    selected = endpoint_rows(server, endpoint)
    if not selected:
        raise SystemExit(f"missing rows for {server} {endpoint}")
    return median([row["summary"]["requests_per_sec"] for row in selected])

def repeat_text(server, endpoint):
    selected = endpoint_rows(server, endpoint)
    return ",".join(f"{row['latency_seconds']['p99'] * 1_000_000.0:.0f}" for row in selected)

metrics = {}

eta_dynamic = {endpoint: endpoint_p99_us("eta", endpoint) for endpoint in DYNAMIC_ENDPOINTS}
nginx_dynamic = {endpoint: endpoint_p99_us("nginx", endpoint) for endpoint in DYNAMIC_ENDPOINTS}
eta_guards = {endpoint: endpoint_p99_us("eta", endpoint) for endpoint in GUARD_ENDPOINTS}

metrics["h2_tls_spread_success"] = 1.0
metrics["h2_tls_spread_tiny_p99_geomean_us"] = geomean(list(eta_dynamic.values()))
metrics["h2_tls_spread_tiny_vs_nginx_p99_ratio_geomean"] = geomean(
    [eta_dynamic[endpoint] / nginx_dynamic[endpoint] for endpoint in DYNAMIC_ENDPOINTS]
)
metrics["h2_tls_spread_tiny_rps_geomean"] = geomean(
    [endpoint_rps("eta", endpoint) for endpoint in DYNAMIC_ENDPOINTS]
)

for endpoint, value in eta_dynamic.items():
    metrics[f"h2_tls_spread_{endpoint}_p99_us"] = value
    metrics[f"h2_tls_spread_{endpoint}_vs_nginx_p99_ratio"] = value / nginx_dynamic[endpoint]
for endpoint, value in nginx_dynamic.items():
    metrics[f"nginx_h2_tls_spread_{endpoint}_p99_us"] = value
for endpoint, value in eta_guards.items():
    metrics[f"h2_tls_spread_{endpoint}_p99_us"] = value
    metrics[f"h2_tls_spread_{endpoint}_rps"] = endpoint_rps("eta", endpoint)

print("server\tendpoint\tp99_us\trps\tp99_repeats_us")
for server in ["eta", "nginx"]:
    for endpoint in DYNAMIC_ENDPOINTS:
        print(
            f"{server}\t{endpoint}\t"
            f"{endpoint_p99_us(server, endpoint):.0f}\t"
            f"{endpoint_rps(server, endpoint):.0f}\t"
            f"{repeat_text(server, endpoint)}"
        )
for endpoint in GUARD_ENDPOINTS:
    print(
        f"eta\t{endpoint}\t"
        f"{endpoint_p99_us('eta', endpoint):.0f}\t"
        f"{endpoint_rps('eta', endpoint):.0f}\t"
        f"{repeat_text('eta', endpoint)}"
    )

for name in sorted(metrics):
    print(f"METRIC {name}={metrics[name]:.6f}")
print(f"server_load_json={path}", file=sys.stderr)
PY
