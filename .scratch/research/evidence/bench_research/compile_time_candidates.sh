#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

start="$(date +%s%3N)"
dune build packages/effet >/dev/null
end="$(date +%s%3N)"
printf 'date_ms=%s\n' "$((end - start))"

if command -v /usr/bin/time >/dev/null 2>&1; then
  /usr/bin/time -f 'time_elapsed_s=%e max_rss_kb=%M' dune build packages/effet >/dev/null
else
  printf 'time_elapsed_s=unavailable max_rss_kb=unavailable\n'
fi
