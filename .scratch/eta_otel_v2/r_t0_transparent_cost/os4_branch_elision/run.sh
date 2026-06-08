#!/usr/bin/env bash
set -euo pipefail

exe="_build/default/bench/r_t0_branch_elision/r_t0_branch_elision.exe"

nix develop -c dune build bench/r_t0_branch_elision/r_t0_branch_elision.exe
nix develop -c dune exec bench/r_t0_branch_elision/r_t0_branch_elision.exe

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

nm "$exe" >"$tmp/nm.txt"

entry="$(awk '/R_t0_branch_elision__entry$/ { print $3; exit }' "$tmp/nm.txt")"
noop="$(awk '/R_t0_branch_elision__named_2_/ { print $3; exit }' "$tmp/nm.txt")"
observed="$(awk '/R_t0_branch_elision__named_3_/ { print $3; exit }' "$tmp/nm.txt")"

if [ -z "$entry" ] || [ -z "$noop" ] || [ -z "$observed" ]; then
  echo "missing expected symbols" >&2
  exit 2
fi

objdump -d --disassemble="$entry" "$exe" >"$tmp/entry.asm"
objdump -d --disassemble="$noop" "$exe" >"$tmp/noop.asm"
objdump -d --disassemble="$observed" "$exe" >"$tmp/observed.asm"

dynamic_observer_branches="$({ rg 'cmp\s+\$0x1|jne' "$tmp/entry.asm" || true; } | wc -l | tr -d ' ')"
noop_observer_branches="$({ rg 'cmp\s+\$0x1|jne' "$tmp/noop.asm" || true; } | wc -l | tr -d ' ')"
observed_observer_branches="$({ rg 'cmp\s+\$0x1|jne' "$tmp/observed.asm" || true; } | wc -l | tr -d ' ')"

printf 'entry_symbol=%s\n' "$entry"
printf 'noop_symbol=%s\n' "$noop"
printf 'observed_symbol=%s\n' "$observed"
printf 'dynamic_observer_branch_markers=%s\n' "$dynamic_observer_branches"
printf 'noop_observer_branch_markers=%s\n' "$noop_observer_branches"
printf 'observed_observer_branch_markers=%s\n' "$observed_observer_branches"

printf '\n-- dynamic entry observer-branch excerpt --\n'
rg -n -C 3 'cmp\s+\$0x1|jne' "$tmp/entry.asm" || true

printf '\n-- generated no-observer body --\n'
cat "$tmp/noop.asm"

if [ "$dynamic_observer_branches" -lt 2 ]; then
  echo "expected dynamic runtime path to contain observer branch markers" >&2
  exit 3
fi

if [ "$noop_observer_branches" -ne 0 ]; then
  echo "generated no-observer path still contains observer branch markers" >&2
  exit 4
fi
