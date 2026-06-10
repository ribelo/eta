#!/usr/bin/env bash
set -euo pipefail

root="${1:-lib/http}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

dep_pattern='Eta_eio|Eio\.'
escape_pattern='Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+'

dep_sites="$(mktemp)"
escape_sites="$(mktemp)"
trap 'rm -f "$dep_sites" "$escape_sites"' EXIT

rg -n -t ocaml "$dep_pattern" "$root" >"$dep_sites" || true
if [ -f "$root/dune" ]; then
  rg -n '(^|[[:space:]])(eta_eio|eta_http_eio|eio|eio\.unix)($|[[:space:]])' "$root/dune" >>"$dep_sites" || true
fi
rg -n -t ocaml "$escape_pattern" "$root" | rg -v 'Atomic\.Portable' >"$escape_sites" || true

dep_count="$(wc -l <"$dep_sites" | tr -d ' ')"
escape_count="$(wc -l <"$escape_sites" | tr -d ' ')"

update_header () {
  local file="$1"
  local count="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v timestamp="$timestamp" -v count="$count" '
    /^Last updated:/ { print "Last updated: " timestamp; next }
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
fi

if [ "$escape_count" -gt 0 ]; then
  printf '\nEta escape matches:\n'
  cat "$escape_sites"
fi
