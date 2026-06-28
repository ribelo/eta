#!/usr/bin/env bash
set -euo pipefail

root="${1:-lib/http}"
dep_pattern='Eta_eio|Eio\.|Eta_http_eio|Eta_http_js|Eta_http_h1|Eta_http_h2|Eta_http_ws|Eta_http_tls_openssl|Js_of_ocaml|Unix\.'
escape_pattern='Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+'

dep_sites="$(mktemp)"
escape_sites="$(mktemp)"
trap 'rm -f "$dep_sites" "$escape_sites"' EXIT

rg --sort path -n -t ocaml "$dep_pattern" "$root" \
  -g '!**/h1/**' \
  -g '!**/h2/**' \
  -g '!**/ws/**' >"$dep_sites" || true
if [ -f "$root/dune" ]; then
  rg --sort path -n '(^|[[:space:]])(eta_eio|eta_http_eio|eta_http_js|eta_http_h1|eta_http_h2|eta_http_ws|eta_http_tls_openssl|eio|eio\.unix|js_of_ocaml|base64|cstruct|faraday|angstrom|conf-openssl|conf-pkg-config|unix)($|[[:space:]])' "$root/dune" >>"$dep_sites" || true
fi
rg --sort path -n -t ocaml "$escape_pattern" "$root" \
  -g '!**/h1/**' \
  -g '!**/h2/**' \
  -g '!**/ws/**' | rg -v 'Atomic\.Portable' >"$escape_sites" || true

dep_count="$(wc -l <"$dep_sites" | tr -d ' ')"
escape_count="$(wc -l <"$escape_sites" | tr -d ' ')"

update_header () {
  local file="$1"
  local count="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v count="$count" '
    /^Current sites:/ { print "Current sites: " count; next }
    { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

update_header "$root/audit/dep_usage.md" "$dep_count"
update_header "$root/audit/eta_escapes.md" "$escape_count"

printf 'Backend dependency sites: %s\n' "$dep_count"
printf 'Eta escape sites: %s\n' "$escape_count"

if [ "$dep_count" -gt 0 ]; then
  printf '\nDependency site matches:\n'
  cat "$dep_sites"
  exit 1
fi

if [ "$escape_count" -gt 0 ]; then
  printf '\nEta escape matches:\n'
  cat "$escape_sites"
fi
