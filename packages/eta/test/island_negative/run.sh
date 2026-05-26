#!/usr/bin/env bash
set -u

cmxa="$1"
fixture_dir="$(dirname "$0")"
obj_dir="$(dirname "$cmxa")/.eta.objs/byte"
par_cmxa="$(dirname "$cmxa")/../par/par.cmxa"
par_obj_dir="$(dirname "$cmxa")/../par/.par.objs/byte"
tmp_dir="${TMPDIR:-/tmp}/eta-island-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  exe="$tmp_dir/${name%.ml}.exe"

  if ocamlfind ocamlopt -extension-universe alpha \
      -package "eio,eio_main,portable,unix,threads" \
      -linkpkg -I "$par_obj_dir" -I "$obj_dir" "$par_cmxa" "$cmxa" "$src" -o "$exe" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eq "portable|shareable|contended|local|mode" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

exit "$status"
