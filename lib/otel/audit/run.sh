#!/usr/bin/env bash
set -euo pipefail

root="${1:-lib/otel}"
dep_pattern='Eta_http\.|Eta_stream\.|Eio\.|Yojson\.'
escape_pattern='Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+'

dep_sites="$(mktemp)"
escape_sites="$(mktemp)"
trap 'rm -f "$dep_sites" "$escape_sites"' EXIT

rg --sort path -n -t ocaml "$dep_pattern" "$root" >"$dep_sites" || true
rg --sort path -n -t ocaml "$escape_pattern" "$root" | rg -v 'Atomic\.Portable' >"$escape_sites" || true

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

update_matches () {
  local file="$1"
  local marker="$2"
  local sites="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v marker="$marker" -v sites="$sites" '
    $0 == "<!-- BEGIN " marker " -->" {
      print
      while ((getline line < sites) > 0) {
        print "- " line
      }
      close(sites)
      skip = 1
      next
    }
    $0 == "<!-- END " marker " -->" {
      skip = 0
      print
      next
    }
    skip != 1 { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

update_header "$root/audit/dep_usage.md" "$dep_count"
update_header "$root/audit/eta_escapes.md" "$escape_count"
update_matches "$root/audit/dep_usage.md" "DEP_MATCHES" "$dep_sites"
update_matches "$root/audit/eta_escapes.md" "ESCAPE_MATCHES" "$escape_sites"

printf 'Dependency sites: %s\n' "$dep_count"
printf 'Eta escape sites: %s\n' "$escape_count"
