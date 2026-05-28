#!/usr/bin/env bash
set -u

fixture_dir="$(dirname "$0")"
obj_dir="_build/default/lib/eta/.eta.objs/byte"
tmp_dir="${TMPDIR:-/tmp}/eta-letat-p2-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"

  if ocamlc -I "$obj_dir" -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eiq "expected of type|Eta\.Effect\.t|Effect\.t" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n "1,120p" "$log"
    status=1
  else
    echo "$name PASS compile-fail"
    sed -n "1,80p" "$log"
  fi
done

exit "$status"
