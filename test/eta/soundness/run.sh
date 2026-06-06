#!/usr/bin/env bash
set -u

cmxa="$1"
fixture_dir="$(dirname "$0")"
obj_dir="$(dirname "$cmxa")/.eta.objs/native"
par_obj_dir="$(dirname "$cmxa")/../par/.eta_par.objs/native"
tmp_dir="${TMPDIR:-/tmp}/eta-soundness-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmx"

  if ocamlfind ocamlopt -extension-universe alpha \
      -package "eio,eio_main,portable,unix,threads" \
      -I "$par_obj_dir" -I "$obj_dir" -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eiq "portable|shareable|contended|local|mode|nonportable|immutable|global|uniqueness|unbound" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

exit "$status"
