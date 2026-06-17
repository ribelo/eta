#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"

REQUESTS="${ETA_H1_PLAIN_ECHO_REQUESTS:-24000}"
REPEATS="${ETA_H1_PLAIN_ECHO_REPEATS:-9}"
CONCURRENCY="${ETA_H1_PLAIN_ECHO_CONCURRENCY:-16}"
TIMEOUT="${ETA_H1_PLAIN_ECHO_TIMEOUT:-10s}"
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

cd "$ROOT"
mkdir -p "$RESULT_DIR"

require_command oha
require_command go
require_command curl

echo "building Eta H1 probe" >&2
nix develop -c dune build http-testsuite/test/server_load/h1_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python -c 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"x" * 1024)' "$BODY_1K"

GO_SOURCE="$TMP_DIR/go_h1_server.go"
GO_BIN="$TMP_DIR/go_h1_server"
cat >"$GO_SOURCE" <<'GO'
package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func main() {
	if len(os.Args) != 3 {
		panic("usage: go_h1_server PORT ROOT")
	}
	port, err := strconv.Atoi(os.Args[1])
	if err != nil {
		panic(err)
	}
	root := os.Args[2]

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case r.Method == "GET" && path == "/":
			w.WriteHeader(http.StatusOK)
		case r.Method == "GET" && path == "/healthz":
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte("ok\n"))
		case r.Method == "GET" && strings.HasPrefix(path, "/user/"):
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte(strings.TrimPrefix(path, "/user/")))
		case r.Method == "POST" && path == "/user":
			_, _ = io.Copy(io.Discard, r.Body)
			w.WriteHeader(http.StatusOK)
		case r.Method == "POST" && path == "/echo":
			body, err := io.ReadAll(r.Body)
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write(body)
		case r.Method == "GET" && strings.HasPrefix(path, "/static/"):
			http.ServeFile(w, r, filepath.Join(root, strings.TrimPrefix(path, "/static/")))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})

	server := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", port),
		Handler: mux,
	}
	panic(server.ListenAndServe())
}
GO

echo "building Go H1 reference" >&2
go build -o "$GO_BIN" "$GO_SOURCE"

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

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

wait_http_ready() {
  local port="$1"
  for _ in $(seq 1 200); do
    if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" | grep -q '^200$'; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

random_port() {
  python - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_eta_server() {
  cleanup_server
  local port
  port="$(random_port)"
  local server_tmp="$TMP_DIR/eta-server"
  local server_log="$RESULT_DIR/eta-server.log"
  mkdir -p "$server_tmp"

  local server_cmd=("_build/default/http-testsuite/test/server_load/h1_probe.exe" "$port" "$server_tmp")
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
      echo "Eta H1 server exited before ready" >&2
      sed -n '1,160p' "$server_log" >&2
      exit 1
    fi
    sleep 0.05
  done

  echo "Eta H1 server did not become ready" >&2
  sed -n '1,160p' "$server_log" >&2
  exit 1
}

start_go_server() {
  cleanup_server
  local port
  port="$(random_port)"
  local server_tmp="$TMP_DIR/go-server"
  local server_log="$RESULT_DIR/go-server.log"
  write_fixtures "$server_tmp"

  local server_cmd=("$GO_BIN" "$port" "$server_tmp")
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
  fi

  "${server_cmd[@]}" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  if ! wait_http_ready "$port"; then
    echo "Go H1 server did not become ready" >&2
    sed -n '1,160p' "$server_log" >&2
    exit 1
  fi

  printf '%s' "$port"
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
    -c "$CONCURRENCY"
    -n "$REQUESTS"
    --http-version 1.1
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
    echo "$server repeat $repeat/$REPEATS: H1 root/user/post/static/echo" >&2
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

GO_PORT="$(start_go_server)"
run_endpoint_set go "$GO_PORT"
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
servers = ["eta", "go"]

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
metrics["h1_plain_echo_1k_success"] = 1.0 if all(row["ok"] for row in rows) else 0.0

summary_rows = []
for endpoint, _expected_body_bytes in endpoints:
    endpoint_summary = {"endpoint": endpoint}
    for server in servers:
        case_rows = [
            row for row in rows
            if row["server"] == server and row["endpoint"] == endpoint
        ]
        prefix = f"h1_plain_{server}_{endpoint}"
        for field in ["rps", "p50_us", "p95_us", "p99_us", "p999_us", "max_us"]:
            value = median([row[field] for row in case_rows])
            metrics[f"{prefix}_{field}"] = value
            endpoint_summary[f"{server}_{field}"] = value
        endpoint_summary[f"{server}_success"] = all(row["ok"] for row in case_rows)
    rps_ratio = (
        endpoint_summary["eta_rps"] / endpoint_summary["go_rps"]
        if endpoint_summary["go_rps"] > 0
        else 0.0
    )
    p99_ratio = (
        endpoint_summary["eta_p99_us"] / endpoint_summary["go_p99_us"]
        if endpoint_summary["go_p99_us"] > 0
        else 0.0
    )
    metrics[f"h1_plain_{endpoint}_eta_go_rps_ratio"] = rps_ratio
    metrics[f"h1_plain_{endpoint}_eta_go_p99_ratio"] = p99_ratio
    endpoint_summary["eta_go_rps_ratio"] = rps_ratio
    endpoint_summary["eta_go_p99_ratio"] = p99_ratio
    summary_rows.append(endpoint_summary)

metrics["h1_plain_echo_1k_eta_go_rps_ratio"] = metrics[
    "h1_plain_echo_1k_eta_go_rps_ratio"
]
metrics["h1_plain_echo_1k_eta_rps"] = metrics["h1_plain_eta_echo_1k_rps"]
metrics["h1_plain_echo_1k_go_rps"] = metrics["h1_plain_go_echo_1k_rps"]
metrics["h1_plain_echo_1k_eta_p99_us"] = metrics["h1_plain_eta_echo_1k_p99_us"]
metrics["h1_plain_echo_1k_go_p99_us"] = metrics["h1_plain_go_echo_1k_p99_us"]
metrics["h1_plain_echo_1k_eta_go_p99_ratio"] = metrics[
    "h1_plain_echo_1k_eta_go_p99_ratio"
]
metrics["h1_plain_eta_go_rps_ratio_geomean"] = geomean(
    [row["eta_go_rps_ratio"] for row in summary_rows]
)
metrics["h1_plain_non_echo_eta_go_rps_ratio_geomean"] = geomean(
    [
        row["eta_go_rps_ratio"]
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
        f"eta_rps={row['eta_rps']:.0f} go_rps={row['go_rps']:.0f} "
        f"rps_ratio={row['eta_go_rps_ratio']:.3f} "
        f"eta_p99_us={row['eta_p99_us']:.1f} go_p99_us={row['go_p99_us']:.1f} "
        f"p99_ratio={row['eta_go_p99_ratio']:.3f}"
    )
for name in sorted(metrics):
    print(f"METRIC {name}={metrics[name]:.9g}")
PY
