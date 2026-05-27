#!/usr/bin/env bash
set -euo pipefail

root="${1:-lib/ai/openai}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

dep_pattern='Ai\.|Redacted\.|Http\.|Eta\.(Effect|Redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken'
escape_pattern='Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+'

dep_sites="$(mktemp)"
escape_sites="$(mktemp)"
trap 'rm -f "$dep_sites" "$escape_sites"' EXIT

rg -n -t ocaml "$dep_pattern" "$root" >"$dep_sites" || true
rg -n -t ocaml "$escape_pattern" "$root" >"$escape_sites" || true

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

if [ "$dep_count" -gt 0 ]; then
  printf '\nDependency site matches:\n'
  sed -n '1,200p' "$dep_sites"
fi

if [ "$escape_count" -gt 0 ]; then
  printf '\nEta escape matches:\n'
  sed -n '1,200p' "$escape_sites"
fi
