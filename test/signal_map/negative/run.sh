#!/usr/bin/env bash
set -u

eta_signal_map_cma="$1"
eta_signal_map_dir="$(dirname "$eta_signal_map_cma")"
fixture_dir="$(dirname "$0")"
tmp_dir="${TMPDIR:-/tmp}/eta-signal-map-negative-$$"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

status=0

compile_fixture() {
  local src="$1"
  local obj="$2"
  local log="$3"

  ocamlfind ocamlc \
    -I "$eta_signal_map_dir/.eta_signal_map.objs/byte" \
    -c "$src" -o "$obj" >"$log" 2>&1
}

for src in "$fixture_dir"/*_positive.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"
  if ! compile_fixture "$src" "$obj" "$log"; then
    echo "expected positive fixture to compile, but it failed: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"
  if compile_fixture "$src" "$obj" "$log"; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eq 'Left\.t|Right\.t|incompatible|not compatible' "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

exit "$status"
