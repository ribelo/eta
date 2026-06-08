#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
rel_case_dir="scratch/eta_http_research/h_q4a_interop_matrix"
case_dir="$root/$rel_case_dir"
tmp="$(mktemp -d)"

nginx_http_port="18080"
nginx_https_port="18443"
caddy_http_port="19080"
caddy_https_port="19443"
nghttpd_https_port="20443"
nginx_pid=""
caddy_pid=""
nghttpd_pid=""

mkdir -p "$tmp/www" "$tmp/client_body_temp"
truncate -s 104857600 "$tmp/www/large.bin"
printf 'nghttpd-ok\n' >"$tmp/www/ok"
printf 'main-push\n' >"$tmp/www/push.html"
printf 'pushed\n' >"$tmp/www/pushed.txt"
{
  for _ in $(seq 1 4096); do
    printf ':\n\ndata: heartbeat\n\n'
  done
} >"$tmp/www/sse-long.txt"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$tmp/key.pem" \
  -out "$tmp/cert.pem" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -days 1 >/dev/null 2>&1

sed \
  -e "s#__TMP_DIR__#$tmp#g" \
  -e "s#__WWW_DIR__#$tmp/www#g" \
  -e "s#__CERT_FILE__#$tmp/cert.pem#g" \
  -e "s#__KEY_FILE__#$tmp/key.pem#g" \
  -e "s#__NGINX_HTTP_PORT__#$nginx_http_port#g" \
  -e "s#__NGINX_HTTPS_PORT__#$nginx_https_port#g" \
  "$case_dir/configs/nginx.conf.in" >"$tmp/nginx.conf"

cleanup () {
  if [ -n "$nginx_pid" ]; then kill "$nginx_pid" 2>/dev/null || true; fi
  if [ -n "$caddy_pid" ]; then kill "$caddy_pid" 2>/dev/null || true; fi
  if [ -n "$nghttpd_pid" ]; then kill "$nghttpd_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

nginx -c "$tmp/nginx.conf" -p "$tmp/nginx-prefix" >"$tmp/nginx-stdout.log" 2>&1 &
nginx_pid="$!"

WWW_DIR="$tmp/www" \
CERT_FILE="$tmp/cert.pem" \
KEY_FILE="$tmp/key.pem" \
CADDY_HTTP_PORT="$caddy_http_port" \
CADDY_HTTPS_PORT="$caddy_https_port" \
  caddy run --config "$case_dir/configs/Caddyfile" --adapter caddyfile \
  >"$tmp/caddy.log" 2>&1 &
caddy_pid="$!"

nghttpd -v -a 127.0.0.1 -d "$tmp/www" -p/push.html=/pushed.txt \
  "$nghttpd_https_port" "$tmp/key.pem" "$tmp/cert.pem" \
  >"$tmp/nghttpd.log" 2>&1 &
nghttpd_pid="$!"

wait_for () {
  local url="$1"
  local curl_flags="$2"
  for _ in $(seq 1 80); do
    if curl $curl_flags -sS --max-time 1 "$url/ok" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "server did not become ready: $url" >&2
  echo "nginx log:" >&2
  cat "$tmp/nginx-error.log" >&2 || true
  echo "caddy log:" >&2
  cat "$tmp/caddy.log" >&2 || true
  echo "nghttpd log:" >&2
  cat "$tmp/nghttpd.log" >&2 || true
  return 1
}

wait_for "http://127.0.0.1:$nginx_http_port" ""
wait_for "https://127.0.0.1:$nginx_https_port" "-k"
wait_for "http://127.0.0.1:$caddy_http_port" ""
wait_for "https://127.0.0.1:$caddy_https_port" "-k"
wait_for "https://127.0.0.1:$nghttpd_https_port" "-k --http2"

dune build "$rel_case_dir/eta_probe.exe"

results="$case_dir/results.tsv"
: >"$results"
printf 'id\timplementation\tscenario\tstatus\tdetail\n' >>"$results"

run_case () {
  local id="$1"
  local implementation="$2"
  local scenario="$3"
  local expect="$4"
  shift 4
  local output="$tmp/$id.out"
  local status="PASS"
  if ! "$@" >"$output" 2>&1; then
    status="FAIL"
  elif ! grep -Eq "$expect" "$output"; then
    status="FAIL"
  fi
  local detail
  detail="$(tr '\000\r\n\t' '    ' <"$output" | sed 's/  */ /g' | cut -c 1-240)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$implementation" "$scenario" "$status" "$detail" >>"$results"
  if [ "$status" = "FAIL" ]; then
    echo "FAIL $id $scenario" >&2
    cat "$output" >&2
    return 1
  fi
}

run_case_expect_fail () {
  local id="$1"
  local implementation="$2"
  local scenario="$3"
  local expect="$4"
  shift 4
  local output="$tmp/$id.out"
  local status="PASS"
  if "$@" >"$output" 2>&1; then
    status="FAIL"
  elif ! grep -Eq "$expect" "$output"; then
    status="FAIL"
  fi
  local detail
  detail="$(tr '\r\n\t' '   ' <"$output" | sed 's/  */ /g' | cut -c 1-240)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$implementation" "$scenario" "$status" "$detail" >>"$results"
  if [ "$status" = "FAIL" ]; then
    echo "FAIL $id $scenario" >&2
    cat "$output" >&2
    return 1
  fi
}

run_nghttpd_push_case () {
  local id="$1"
  local output="$tmp/$id.out"
  local status="PASS"
  : >"$tmp/nghttpd.log"
  if ! eta_probe --insecure "https://127.0.0.1:$nghttpd_https_port/push.html" \
      >"$output" 2>&1; then
    status="FAIL"
  else
    grep -aE "SETTINGS_ENABLE_PUSH\(0x02\):0|PUSH_PROMISE|stream_id=2" \
      "$tmp/nghttpd.log" >>"$output" || true
    if ! grep -Eq "outcome=ok .*status=200 .*body_bytes=10" "$output" \
        || ! grep -Eq "SETTINGS_ENABLE_PUSH\(0x02\):0" "$output"; then
      status="FAIL"
    fi
  fi
  local detail
  detail="$(tr '\r\n\t' '   ' <"$output" | sed 's/  */ /g' | cut -c 1-240)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "eta-http" \
    "nghttpd server-push rejection" "$status" "$detail" >>"$results"
  if [ "$status" = "FAIL" ]; then
    echo "FAIL $id nghttpd server-push rejection" >&2
    cat "$output" >&2
    return 1
  fi
}

run_nginx_mid_body_close_case () {
  local id="$1"
  local output="$tmp/$id.out"
  local status="PASS"
  eta_probe --h1-only "http://127.0.0.1:$nginx_http_port/large-slow.bin" \
    >"$output" 2>&1 &
  local probe_pid="$!"
  sleep 0.5
  local nginx_children
  nginx_children="$(pgrep -P "$nginx_pid" || true)"
  if [ -n "$nginx_children" ]; then kill -9 $nginx_children 2>/dev/null || true; fi
  local killed_nginx_pid="$nginx_pid"
  kill -9 "$killed_nginx_pid" 2>/dev/null || true
  nginx_pid=""
  wait "$killed_nginx_pid" 2>/dev/null || true
  if wait "$probe_pid"; then
    status="FAIL"
  elif ! grep -Eq "Connection_closed|connection_closed|Http_response" "$output"; then
    status="FAIL"
  fi
  local detail
  detail="$(tr '\r\n\t' '   ' <"$output" | sed 's/  */ /g' | cut -c 1-240)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "eta-http" \
    "nginx mid-body close" "$status" "$detail" >>"$results"
  if [ "$status" = "FAIL" ]; then
    echo "FAIL $id nginx mid-body close" >&2
    cat "$output" >&2
    return 1
  fi
}

eta_probe () {
  dune exec "$rel_case_dir/eta_probe.exe" -- "$@"
}

run_case c01 curl "nginx h1 GET" "nginx-ok" \
  curl -sS "http://127.0.0.1:$nginx_http_port/ok"

run_case c02 curl "nginx h2 ALPN" "HTTP/2 200|HTTP/2" \
  curl -k -sS -i --http2 "https://127.0.0.1:$nginx_https_port/ok"

run_case c03 nghttp2 "nginx h2 ALPN" "recv \(stream_id=13\) :status: 200|The negotiated protocol: h2" \
  nghttp -y -nv "https://127.0.0.1:$nginx_https_port/ok"

run_case c04 eta-http "nginx h1 GET" "outcome=ok repeat=1 status=200 body_bytes=9" \
  eta_probe --h1-only "http://127.0.0.1:$nginx_http_port/ok"

run_case c05 eta-http "nginx keep-alive repeat" "outcome=ok repeat=2 status=200 body_bytes=9" \
  eta_probe --h1-only --repeat 2 "http://127.0.0.1:$nginx_http_port/ok"

run_case c06 eta-http "nginx redirect not followed" "outcome=ok repeat=1 status=302 .*location=\".*(/ok)\"" \
  eta_probe --h1-only "http://127.0.0.1:$nginx_http_port/redirect"

run_case c07 eta-http "nginx HEAD no body" "outcome=ok repeat=1 status=200 body_bytes=0" \
  eta_probe --h1-only --method HEAD "http://127.0.0.1:$nginx_http_port/head"

run_case c08 eta-http "nginx early 413" "outcome=ok repeat=1 status=413" \
  eta_probe --h1-only --method POST --body-size 2048 "http://127.0.0.1:$nginx_http_port/early413"

run_case c09 eta-http "nginx SSE heartbeat body" "outcome=ok repeat=1 status=200 body_bytes=20 .*text/event-stream" \
  eta_probe --h1-only "http://127.0.0.1:$nginx_http_port/sse"

run_case c10 eta-http "nginx WebSocket upgrade rejection" "outcome=ok repeat=1 status=426" \
  eta_probe --h1-only --header "Connection: Upgrade" --header "Upgrade: websocket" \
    "http://127.0.0.1:$nginx_http_port/ws"

run_case c11 eta-http "nginx large body 100MB" "outcome=ok repeat=1 status=200 body_bytes=104857600" \
  eta_probe --h1-only "http://127.0.0.1:$nginx_http_port/large.bin"

run_case c12 eta-http "nginx h1 trailers" "outcome=ok repeat=1 status=200 .*trailer_x=\"nginx-trailer\"" \
  eta_probe --h1-only --header "TE: trailers" "http://127.0.0.1:$nginx_http_port/trailers"

run_case c13 eta-http "nginx TLS h1 fallback" "outcome=ok repeat=1 status=200 body_bytes=9" \
  eta_probe --h1-only --insecure "https://127.0.0.1:$nginx_https_port/ok"

run_case c14 eta-http "caddy h1 GET" "outcome=ok repeat=1 status=200 body_bytes=10" \
  eta_probe --h1-only "http://127.0.0.1:$caddy_http_port/ok"

run_case c15 curl "caddy h2c prior knowledge" "caddy-ok" \
  curl -sS --http2-prior-knowledge "http://127.0.0.1:$caddy_http_port/ok"

run_case c16 nghttp2 "caddy h2c prior knowledge" "recv \(stream_id=[0-9]+\) :status: 200" \
  nghttp -nv "http://127.0.0.1:$caddy_http_port/ok"

run_case c17 eta-http "caddy h2 ALPN zero-byte body" "outcome=ok repeat=1 status=200 body_bytes=0" \
  eta_probe --insecure "https://127.0.0.1:$caddy_https_port/empty"

run_case c18 eta-http "caddy h2 ALPN GET" "outcome=ok repeat=1 status=200 body_bytes=10" \
  eta_probe --insecure "https://127.0.0.1:$caddy_https_port/ok"

run_case c19 eta-http "caddy WebSocket upgrade rejection" "outcome=ok repeat=1 status=426" \
  eta_probe --h1-only --header "Connection: Upgrade" --header "Upgrade: websocket" \
    "http://127.0.0.1:$caddy_http_port/ws"

run_case c20 nghttp2 "nghttpd server-push fixture" "PUSH_PROMISE" \
  nghttp -ansv "https://127.0.0.1:$nghttpd_https_port/push.html"

run_nghttpd_push_case c21

run_case c22 eta-http "caddy h2 ALPN large body 100MB" "outcome=ok repeat=1 status=200 body_bytes=104857600" \
  eta_probe --insecure "https://127.0.0.1:$caddy_https_port/large.bin"

run_case c23 eta-http "nginx 100-Continue final response" "outcome=ok repeat=1 status=200 body_bytes=10" \
  eta_probe --h1-only --method POST --body-size 6 --header "Expect: 100-continue" \
    "http://127.0.0.1:$nginx_http_port/continue"

run_case c24 eta-http "nginx SSE long-held first heartbeat" "outcome=ok repeat=1 status=200 .*complete=false .*text/event-stream" \
  eta_probe --h1-only --read-chunks 1 "http://127.0.0.1:$nginx_http_port/sse-long"

run_nginx_mid_body_close_case c25

{
  echo "# H-Q4a Interop Matrix Results"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "| ID | Implementation | Scenario | Status | Detail |"
  echo "| --- | --- | --- | --- | --- |"
  tail -n +2 "$results" | while IFS=$'\t' read -r id implementation scenario status detail; do
    printf '| %s | %s | %s | %s | %s |\n' "$id" "$implementation" "$scenario" "$status" "$detail"
  done
} >"$case_dir/results.md"

cat "$case_dir/results.md"
