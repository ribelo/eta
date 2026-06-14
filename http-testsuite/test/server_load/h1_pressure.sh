#!/usr/bin/env bash
# HTTP/1.1 plain pressure ladder for Eta vs Node vs Go.
#
# Purpose: find overload points, request loss, and tail-latency cliffs under
# intentionally excessive concurrency. This is not a steady-state latency bench.
#
# Defaults run all three servers across a large c=... ladder on loopback. Tune:
#
#   ETA_H1_PRESSURE_SERVERS="eta node go"
#   ETA_H1_PRESSURE_ENDPOINTS="root post_user static_1k echo_1k"
#   ETA_H1_PRESSURE_CONCURRENCIES="16 32 64 128 256 512 1024 2048 4096"
#   ETA_H1_PRESSURE_REQUESTS=20000
#   ETA_H1_PRESSURE_TIMEOUT=10s
#   ETA_H1_PRESSURE_PIN=1
#   ETA_H1_PRESSURE_SERVER_CORE=2
#   ETA_H1_PRESSURE_LOAD_CORE=3
set -euo pipefail

cd "$(dirname "$0")/../../.."

SERVERS="${ETA_H1_PRESSURE_SERVERS:-eta node go}"
ENDPOINTS="${ETA_H1_PRESSURE_ENDPOINTS:-root post_user static_1k echo_1k}"
CONCURRENCIES="${ETA_H1_PRESSURE_CONCURRENCIES:-16 32 64 128 256 512 1024 2048 4096}"
REQUESTS="${ETA_H1_PRESSURE_REQUESTS:-20000}"
TIMEOUT="${ETA_H1_PRESSURE_TIMEOUT:-10s}"
PIN="${ETA_H1_PRESSURE_PIN:-1}"
SERVER_CORE="${ETA_H1_PRESSURE_SERVER_CORE:-2}"
LOAD_CORE="${ETA_H1_PRESSURE_LOAD_CORE:-3}"
RESULTS_DIR="${ETA_H1_PRESSURE_OUT:-http-testsuite/results/$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git rev-parse --short HEAD)-h1-pressure}"

mkdir -p "$RESULTS_DIR"
ulimit -n 1048576 2>/dev/null || true

pin_prefix() {
  local core="$1"
  if [ "$PIN" != "0" ] && command -v taskset >/dev/null 2>&1; then
    printf "taskset -c %s " "$core"
  fi
}

SERVER_PIN="$(pin_prefix "$SERVER_CORE")"
LOAD_PIN="$(pin_prefix "$LOAD_CORE")"

nix develop -c dune build --profile release \
  http-testsuite/test/server_load/h1_probe.exe >/dev/null

write_node_server() {
  local path="$1"
  cat >"$path" <<'JS'
const http = require("http");
const fs = require("fs");
const path = require("path");

const port = Number(process.argv[2]);
const root = process.argv[3];

function collect(req, cb) {
  const chunks = [];
  req.on("data", chunk => chunks.push(chunk));
  req.on("end", () => cb(Buffer.concat(chunks)));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200);
    res.end();
  } else if (req.method === "GET" && url.pathname === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok\n");
  } else if (req.method === "GET" && url.pathname.startsWith("/user/")) {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(url.pathname.slice("/user/".length));
  } else if (req.method === "POST" && url.pathname === "/user") {
    collect(req, () => {
      res.writeHead(200);
      res.end();
    });
  } else if (req.method === "POST" && url.pathname === "/echo") {
    collect(req, body => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end(body);
    });
  } else if (req.method === "GET" && url.pathname.startsWith("/static/")) {
    const file = path.join(root, url.pathname.slice("/static/".length));
    fs.readFile(file, (err, data) => {
      if (err) {
        res.writeHead(404);
        res.end();
      } else {
        res.writeHead(200);
        res.end(data);
      }
    });
  } else {
    res.writeHead(404);
    res.end();
  }
});

server.listen(port, "127.0.0.1");
JS
}

write_go_server() {
  local path="$1"
  cat >"$path" <<'GO'
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
	port, err := strconv.Atoi(os.Args[1])
	if err != nil {
		panic(err)
	}
	root := os.Args[2]

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
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

	panic(http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", port), nil))
}
GO
}

endpoint_path() {
  case "$1" in
    root) printf "/" ;;
    user_id) printf "/user/123" ;;
    post_user) printf "/user" ;;
    static_1k) printf "/static/1k.bin" ;;
    echo_1k) printf "/echo" ;;
    *) echo "unknown endpoint: $1" >&2; exit 2 ;;
  esac
}

endpoint_method_args() {
  local endpoint="$1"
  local temp_dir="$2"
  case "$endpoint" in
    post_user)
      printf -- "-m POST -T text/plain"
      ;;
    echo_1k)
      printf x >"$temp_dir/body-echo_1k.bin"
      dd if=/dev/zero bs=1023 count=1 2>/dev/null | tr '\0' x >>"$temp_dir/body-echo_1k.bin"
      printf -- "-m POST -T text/plain -D %q" "$temp_dir/body-echo_1k.bin"
      ;;
    *)
      printf ""
      ;;
  esac
}

prepare_fixtures() {
  local temp_dir="$1"
  printf "" >"$temp_dir/empty.txt"
  dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\0' x >"$temp_dir/1k.bin"
}

random_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_ready() {
  local port="$1"
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

start_server() {
  local server="$1"
  local port="$2"
  local temp_dir="$3"
  local log="$4"

  case "$server" in
    eta)
      ${SERVER_PIN}_build/default/http-testsuite/test/server_load/h1_probe.exe "$port" "$temp_dir" >"$log" 2>&1 &
      ;;
    node)
      write_node_server "$temp_dir/node_h1_server.js"
      ${SERVER_PIN}node "$temp_dir/node_h1_server.js" "$port" "$temp_dir" >"$log" 2>&1 &
      ;;
    go)
      write_go_server "$temp_dir/go_h1_server.go"
      go build -o "$temp_dir/go_h1_server" "$temp_dir/go_h1_server.go"
      ${SERVER_PIN}"$temp_dir/go_h1_server" "$port" "$temp_dir" >"$log" 2>&1 &
      ;;
    *)
      echo "unknown server: $server" >&2
      exit 2
      ;;
  esac
  echo $!
}

run_oha() {
  local server="$1"
  local endpoint="$2"
  local concurrency="$3"
  local port="$4"
  local temp_dir="$5"
  local out_json="$6"
  local out_err="$7"
  local path method_args n

  path="$(endpoint_path "$endpoint")"
  method_args="$(endpoint_method_args "$endpoint" "$temp_dir")"
  n="$REQUESTS"
  if [ "$n" -lt $((concurrency * 20)) ]; then
    n=$((concurrency * 20))
  fi

  set +e
  # shellcheck disable=SC2086
  NO_COLOR=false ${LOAD_PIN}oha --no-tui --output-format json \
    --http-version 1.1 --redirect 0 --disable-compression \
    --connect-timeout 2s -t "$TIMEOUT" -c "$concurrency" -n "$n" \
    $method_args "http://127.0.0.1:$port$path" >"$out_json" 2>"$out_err"
  local status=$?
  set -e

  python3 - "$server" "$endpoint" "$concurrency" "$n" "$status" "$out_json" "$out_err" <<'PY'
import json, sys

server, endpoint, concurrency, requests, exit_status, out_json, out_err = sys.argv[1:]
try:
    with open(out_json) as f:
        data = json.load(f)
    summary = data.get("summary", {})
    latency = data.get("latencyPercentiles", {})
    status_dist = data.get("statusCodeDistribution") or {}
    error_dist = data.get("errorDistribution") or {}
    ok = sum(int(v) for k, v in status_dist.items() if str(k).startswith("2"))
    total_status = sum(int(v) for v in status_dist.values())
    errors = sum(int(v) for v in error_dist.values())
    total = max(total_status + errors, int(requests))
    success_rate = float(summary.get("successRate", 0.0))
    if success_rate > 1.0:
        success_rate /= 100.0
    fields = [
        server,
        endpoint,
        concurrency,
        requests,
        exit_status,
        f"{summary.get('requestsPerSec', 0.0):.2f}",
        f"{latency.get('p50', 0.0) * 1000.0:.3f}",
        f"{latency.get('p95', 0.0) * 1000.0:.3f}",
        f"{latency.get('p99', 0.0) * 1000.0:.3f}",
        f"{summary.get('slowest', 0.0) * 1000.0:.3f}",
        f"{success_rate:.6f}",
        str(ok),
        str(errors),
        json.dumps(error_dist, sort_keys=True).replace(",", ";"),
    ]
except Exception as ex:
    err = ""
    try:
        with open(out_err) as f:
            err = f.read().strip().splitlines()[-1][:200]
    except Exception:
        pass
    fields = [
        server, endpoint, concurrency, requests, exit_status,
        "0.00", "0.000", "0.000", "0.000", "0.000", "0.000000",
        "0", requests, json.dumps({"parse_error": str(ex), "stderr": err}, sort_keys=True).replace(",", ";"),
    ]
print(",".join(str(x) for x in fields))
PY
}

CSV="$RESULTS_DIR/h1_pressure.csv"
SUMMARY="$RESULTS_DIR/summary.md"

{
  echo "server,endpoint,concurrency,requests,exit_status,rps,p50_ms,p95_ms,p99_ms,slowest_ms,success_rate,ok_responses,errors,error_distribution"
} >"$CSV"

for server in $SERVERS; do
  temp_dir="$RESULTS_DIR/$server"
  log="$temp_dir/server.log"
  mkdir -p "$temp_dir"
  prepare_fixtures "$temp_dir"
  port="$(random_port)"
  pid="$(start_server "$server" "$port" "$temp_dir" "$log")"
  cleanup_server() {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  trap cleanup_server EXIT
  if ! wait_ready "$port"; then
    echo "server $server failed readiness; log follows" >&2
    cat "$log" >&2 || true
    cleanup_server
    exit 1
  fi

  for endpoint in $ENDPOINTS; do
    for concurrency in $CONCURRENCIES; do
      out_json="$temp_dir/oha-$endpoint-c$concurrency.json"
      out_err="$temp_dir/oha-$endpoint-c$concurrency.err"
      row="$(run_oha "$server" "$endpoint" "$concurrency" "$port" "$temp_dir" "$out_json" "$out_err")"
      echo "$row" | tee -a "$CSV"
    done
  done
  cleanup_server
  trap - EXIT
done

python3 - "$CSV" "$SUMMARY" <<'PY'
import csv, sys
from collections import defaultdict

csv_path, summary_path = sys.argv[1:]
rows = list(csv.DictReader(open(csv_path)))

def f(row, name):
    try:
        return float(row[name])
    except Exception:
        return 0.0

first_loss = {}
for row in rows:
    key = (row["server"], row["endpoint"])
    if key not in first_loss and (f(row, "success_rate") < 0.999 or int(row["errors"]) > 0):
        first_loss[key] = row

with open(summary_path, "w") as out:
    out.write("# H1 Plain Pressure Summary\n\n")
    out.write(f"- CSV: `{csv_path}`\n")
    out.write("- Loss threshold: success_rate < 0.999 or errors > 0\n\n")
    out.write("## First Loss\n\n")
    out.write("| server | endpoint | concurrency | success | errors | rps | p99 ms |\n")
    out.write("|---|---:|---:|---:|---:|---:|---:|\n")
    for key in sorted(set((r["server"], r["endpoint"]) for r in rows)):
        row = first_loss.get(key)
        if row is None:
            server, endpoint = key
            out.write(f"| {server} | {endpoint} | none | 1.000000 | 0 | - | - |\n")
        else:
            out.write(
                f"| {row['server']} | {row['endpoint']} | {row['concurrency']} | "
                f"{row['success_rate']} | {row['errors']} | {float(row['rps']):.0f} | "
                f"{float(row['p99_ms']):.3f} |\n"
            )
    out.write("\n## Highest Stable RPS Before Loss\n\n")
    out.write("| server | endpoint | concurrency | rps | p99 ms |\n")
    out.write("|---|---:|---:|---:|---:|\n")
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["server"], row["endpoint"])].append(row)
    for key in sorted(grouped):
        stable = [r for r in grouped[key] if f(r, "success_rate") >= 0.999 and int(r["errors"]) == 0]
        if not stable:
            continue
        best = max(stable, key=lambda r: f(r, "rps"))
        out.write(
            f"| {best['server']} | {best['endpoint']} | {best['concurrency']} | "
            f"{float(best['rps']):.0f} | {float(best['p99_ms']):.3f} |\n"
        )

print(summary_path)
PY

echo "h1_pressure csv=$CSV"
echo "h1_pressure summary=$SUMMARY"
