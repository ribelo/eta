#!/usr/bin/env bash
set -euo pipefail

root="${1:-packages/eta-http}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

dep_pattern='H2\.|Hpack\.|Tls\.|Tls_eio\.|Eio\.|Cstruct\.|X509\.|Ca_certs\.|Mirage_crypto|Domain_name\.|Ipaddr\.|Bigstringaf\.|Eqaf\.|Gz\.|De\.'
escape_pattern='Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+'

dep_sites="$(mktemp)"
escape_sites="$(mktemp)"
trap 'rm -f "$dep_sites" "$escape_sites"' EXIT

rg -n -t ocaml "$dep_pattern" "$root" | rg -v 'Http\.H2\.' >"$dep_sites" || true
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

printf 'Dependency sites: %s\n' "$dep_count"
printf 'Eta escape sites: %s\n' "$escape_count"

if [ "$dep_count" -gt 0 ]; then
  printf '\nDependency site matches:\n'
  cat "$dep_sites"
fi

if [ "$escape_count" -gt 0 ]; then
  printf '\nEta escape matches:\n'
  cat "$escape_sites"
fi
