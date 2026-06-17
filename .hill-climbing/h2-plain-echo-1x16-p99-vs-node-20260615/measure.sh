#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"

REQUESTS="${ETA_H2_ECHO_1X16_REQUESTS:-24000}"
REPEATS="${ETA_H2_ECHO_1X16_REPEATS:-9}"
CONNECTIONS="${ETA_H2_ECHO_1X16_CONNECTIONS:-1}"
STREAMS="${ETA_H2_ECHO_1X16_STREAMS:-16}"
TIMEOUT="${ETA_H2_ECHO_1X16_TIMEOUT:-10s}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/$STAMP"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

cleanup() {
  cleanup_server
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

bool_env() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"
  case "${value,,}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  if ! have_command "$1"; then
    echo "$1 is required for this hill" >&2
    exit 2
  fi
}

free_port() {
  python - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

cd "$ROOT"
mkdir -p "$RESULT_DIR"

require_command oha
require_command node

echo "building Eta H2C probe" >&2
nix develop -c dune build http-testsuite/test/server_load/h2_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python -c 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"x" * 1024)' "$BODY_1K"

NODE_SOURCE="$TMP_DIR/node_h2_server.js"
cat >"$NODE_SOURCE" <<'JS'
const http2 = require("http2");
const fs = require("fs");
const path = require("path");

const port = Number(process.argv[2]);
const root = process.argv[3];

function collect(stream, cb) {
  const chunks = [];
  stream.on("data", chunk => chunks.push(chunk));
  stream.on("end", () => cb(Buffer.concat(chunks)));
}

function handle(stream, headers) {
  const method = headers[":method"];
  const url = new URL(headers[":path"], "http://127.0.0.1");
  if (method === "GET" && url.pathname === "/") {
    stream.respond({ ":status": 200 });
    stream.end();
  } else if (method === "GET" && url.pathname === "/healthz") {
    stream.respond({ ":status": 200, "content-type": "text/plain" });
    stream.end("ok\n");
  } else if (method === "GET" && url.pathname.startsWith("/user/")) {
    stream.respond({ ":status": 200, "content-type": "text/plain" });
    stream.end(url.pathname.slice("/user/".length));
  } else if (method === "POST" && url.pathname === "/user") {
    collect(stream, () => {
      stream.respond({ ":status": 200 });
      stream.end();
    });
  } else if (method === "POST" && url.pathname === "/echo") {
    collect(stream, body => {
      stream.respond({ ":status": 200, "content-type": "text/plain" });
      stream.end(body);
    });
  } else if (method === "GET" && url.pathname.startsWith("/static/")) {
    const file = path.join(root, url.pathname.slice("/static/".length));
    fs.readFile(file, (err, data) => {
      if (err) {
        stream.respond({ ":status": 404 });
        stream.end();
      } else {
        stream.respond({ ":status": 200 });
        stream.end(data);
      }
    });
  } else {
    stream.respond({ ":status": 404 });
    stream.end();
  }
}

const server = http2.createServer({ allowHTTP1: true });
server.on("stream", handle);
server.listen(port, "127.0.0.1");
JS

write_fixtures() {
  local dir="$1"
  mkdir -p "$dir"
  python - "$dir" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
(root / "empty.txt").write_bytes(b"")
(root / "1k.bin").write_bytes(b"x" * 1024)
(root / "1m.bin").write_bytes(b"x" * 1024 * 1024)
PY
}

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

start_eta_server() {
  cleanup_server
  local port
  port="$(free_port)"
  local server_tmp="$TMP_DIR/eta-server"
  local server_log="$RESULT_DIR/eta-server.log"
  mkdir -p "$server_tmp"

  local server_cmd=("_build/default/http-testsuite/test/server_load/h2_probe.exe" "$port" "$server_tmp")
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
  fi

  "${server_cmd[@]}" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  for _ in $(seq 1 200); do
    if grep -q "READY $port" "$server_log"; then
      printf '%s' "$port"
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "Eta H2C server exited before ready" >&2
      sed -n '1,160p' "$server_log" >&2
      exit 1
    fi
    sleep 0.05
  done

  echo "Eta H2C server did not become ready" >&2
  sed -n '1,160p' "$server_log" >&2
  exit 1
}

start_node_server() {
  cleanup_server
  local port
  port="$(free_port)"
  local server_tmp="$TMP_DIR/node-server"
  local server_log="$RESULT_DIR/node-server.log"
  write_fixtures "$server_tmp"

  local server_cmd=(node "$NODE_SOURCE" "$port" "$server_tmp")
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
  fi

  "${server_cmd[@]}" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  for _ in $(seq 1 200); do
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      sleep 0.5
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        printf '%s' "$port"
        return 0
      fi
    fi
    sleep 0.05
  done

  echo "Node H2C server exited before ready" >&2
  sed -n '1,160p' "$server_log" >&2
  exit 1
}

run_oha() {
  local server="$1"
  local endpoint="$2"
  local method="$3"
  local path="$4"
  local body_file="$5"
  local repeat="$6"
  local port="$7"
  local raw="$RESULT_DIR/${server}-${endpoint}-${repeat}.json"
  local err="$RESULT_DIR/${server}-${endpoint}-${repeat}.err"
  local url="http://127.0.0.1:${port}${path}"
  local cmd=(
    oha
    --no-tui
    --output-format json
    --redirect 0
    --disable-compression
    --connect-timeout 2s
    -t "$TIMEOUT"
    -c "$CONNECTIONS"
    -p "$STREAMS"
    -n "$REQUESTS"
    --http-version 2
  )

  if [[ "$method" == "POST" ]]; then
    cmd+=(-m POST -T text/plain)
    if [[ -n "$body_file" ]]; then
      cmd+=(-D "$body_file")
    fi
  fi
  cmd+=("$url")

  local runner=()
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    runner=(taskset -c "$LOAD_CORE")
  fi
  env NO_COLOR=false "${runner[@]}" "${cmd[@]}" >"$raw" 2>"$err"
}

run_endpoint_set() {
  local server="$1"
  local port="$2"
  local specs=(
    "root|GET|/||0"
    "user_id|GET|/user/123||3"
    "post_user|POST|/user||0"
    "static_1k|GET|/static/1k.bin||1024"
    "echo_1k|POST|/echo|$BODY_1K|1024"
  )

  for repeat in $(seq 1 "$REPEATS"); do
    echo "$server repeat $repeat/$REPEATS: H2C 1x16 root/user/post/static/echo" >&2
    local spec
    for spec in "${specs[@]}"; do
      IFS='|' read -r endpoint method path body_file _expected_body_bytes <<<"$spec"
      run_oha "$server" "$endpoint" "$method" "$path" "$body_file" "$repeat" "$port"
    done
  done
}

ETA_PORT="$(start_eta_server)"
run_endpoint_set eta "$ETA_PORT"
cleanup_server

NODE_PORT="$(start_node_server)"
run_endpoint_set node "$NODE_PORT"
cleanup_server

python - "$RESULT_DIR" "$REQUESTS" "$REPEATS" <<'PY'
import csv
import json
import math
import statistics
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
requests = int(sys.argv[2])
repeats = int(sys.argv[3])

endpoints = [
    ("root", 0),
    ("user_id", 3),
    ("post_user", 0),
    ("static_1k", 1024),
    ("echo_1k", 1024),
]
servers = ["eta", "node"]

def number(value, default=0.0):
    if value is None:
        return default
    return float(value)

def median(values):
    return statistics.median(values)

def geomean(values):
    if not values or any(value <= 0 for value in values):
        return 0.0
    return math.exp(sum(math.log(value) for value in values) / len(values))

def distribution_total(value):
    if not isinstance(value, dict):
        return 0
    total = 0
    for raw in value.values():
        try:
            total += int(raw)
        except (TypeError, ValueError):
            total += int(float(raw))
    return total

def read_case(server, endpoint, expected_body_bytes, repeat):
    raw_path = result_dir / f"{server}-{endpoint}-{repeat}.json"
    with raw_path.open() as f:
        raw = json.load(f)
    summary = raw.get("summary", {})
    latency = raw.get("latencyPercentiles", {})
    status_dist = raw.get("statusCodeDistribution", {})
    error_dist = raw.get("errorDistribution", {})
    total = distribution_total(status_dist)
    status_200 = int(status_dist.get("200", 0) or 0)
    errors = distribution_total(error_dist)
    total_data = int(round(number(summary.get("totalData"))))
    expected_total_data = expected_body_bytes * requests
    success_rate = number(summary.get("successRate"))
    ok = (
        total == requests
        and status_200 == requests
        and errors == 0
        and abs(success_rate - 1.0) < 0.000001
        and total_data == expected_total_data
    )
    return {
        "server": server,
        "endpoint": endpoint,
        "repeat": repeat,
        "ok": ok,
        "requests": requests,
        "status_200": status_200,
        "errors": errors,
        "total_data": total_data,
        "expected_total_data": expected_total_data,
        "rps": number(summary.get("requestsPerSec")),
        "p50_us": number(latency.get("p50")) * 1_000_000.0,
        "p95_us": number(latency.get("p95")) * 1_000_000.0,
        "p99_us": number(latency.get("p99")) * 1_000_000.0,
        "p999_us": number(latency.get("p99.9")) * 1_000_000.0,
        "max_us": number(summary.get("slowest")) * 1_000_000.0,
    }

rows = [
    read_case(server, endpoint, expected_body_bytes, repeat)
    for server in servers
    for repeat in range(1, repeats + 1)
    for endpoint, expected_body_bytes in endpoints
]

metrics = {}
metrics["h2_plain_echo_1x16_success"] = 1.0 if all(row["ok"] for row in rows) else 0.0

summary_rows = []
for endpoint, _expected_body_bytes in endpoints:
    endpoint_summary = {"endpoint": endpoint}
    for server in servers:
        case_rows = [
            row for row in rows
            if row["server"] == server and row["endpoint"] == endpoint
        ]
        prefix = f"h2_plain_{server}_{endpoint}_1x16"
        for field in ["rps", "p50_us", "p95_us", "p99_us", "p999_us", "max_us"]:
            value = median([row[field] for row in case_rows])
            metrics[f"{prefix}_{field}"] = value
            endpoint_summary[f"{server}_{field}"] = value
        endpoint_summary[f"{server}_success"] = all(row["ok"] for row in case_rows)
    rps_ratio = (
        endpoint_summary["eta_rps"] / endpoint_summary["node_rps"]
        if endpoint_summary["node_rps"] > 0
        else 0.0
    )
    p99_ratio = (
        endpoint_summary["eta_p99_us"] / endpoint_summary["node_p99_us"]
        if endpoint_summary["node_p99_us"] > 0
        else 0.0
    )
    metrics[f"h2_plain_{endpoint}_1x16_eta_node_rps_ratio"] = rps_ratio
    metrics[f"h2_plain_{endpoint}_1x16_eta_node_p99_ratio"] = p99_ratio
    endpoint_summary["eta_node_rps_ratio"] = rps_ratio
    endpoint_summary["eta_node_p99_ratio"] = p99_ratio
    summary_rows.append(endpoint_summary)

metrics["h2_plain_echo_1x16_eta_node_p99_ratio"] = metrics[
    "h2_plain_echo_1k_1x16_eta_node_p99_ratio"
]
metrics["h2_plain_echo_1x16_eta_node_rps_ratio"] = metrics[
    "h2_plain_echo_1k_1x16_eta_node_rps_ratio"
]
metrics["h2_plain_echo_1x16_eta_p99_us"] = metrics[
    "h2_plain_eta_echo_1k_1x16_p99_us"
]
metrics["h2_plain_echo_1x16_node_p99_us"] = metrics[
    "h2_plain_node_echo_1k_1x16_p99_us"
]
metrics["h2_plain_echo_1x16_eta_p999_us"] = metrics[
    "h2_plain_eta_echo_1k_1x16_p999_us"
]
metrics["h2_plain_echo_1x16_eta_rps"] = metrics[
    "h2_plain_eta_echo_1k_1x16_rps"
]
metrics["h2_plain_echo_1x16_node_rps"] = metrics[
    "h2_plain_node_echo_1k_1x16_rps"
]
metrics["h2_plain_non_echo_1x16_eta_node_p99_ratio_geomean"] = geomean(
    [
        row["eta_node_p99_ratio"]
        for row in summary_rows
        if row["endpoint"] != "echo_1k"
    ]
)
metrics["h2_plain_non_echo_1x16_eta_node_rps_ratio_geomean"] = geomean(
    [
        row["eta_node_rps_ratio"]
        for row in summary_rows
        if row["endpoint"] != "echo_1k"
    ]
)

with (result_dir / "rows.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

with (result_dir / "summary.json").open("w") as f:
    json.dump({"metrics": metrics, "summary_rows": summary_rows}, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"RESULT_DIR {result_dir}")
print("Endpoint summary:")
for row in summary_rows:
    print(
        f"  {row['endpoint']:9s} "
        f"eta_rps={row['eta_rps']:.0f} node_rps={row['node_rps']:.0f} "
        f"rps_ratio={row['eta_node_rps_ratio']:.3f} "
        f"eta_p99_us={row['eta_p99_us']:.1f} node_p99_us={row['node_p99_us']:.1f} "
        f"p99_ratio={row['eta_node_p99_ratio']:.3f}"
    )
for name in sorted(metrics):
    print(f"METRIC {name}={metrics[name]:.9g}")

if metrics["h2_plain_echo_1x16_success"] != 1.0:
    raise SystemExit(1)
PY
