#!/usr/bin/env bash
set -u

cmxa="$1"
fixture_dir="$(dirname "$0")"
obj_dir="$(dirname "$cmxa")/.eta.objs/native"
cmi_dir="$(dirname "$cmxa")/.eta.objs/public_cmi"
par_obj_dir="$(dirname "$cmxa")/../par/.eta_par.objs/native"
par_cmi_dir="$(dirname "$cmxa")/../par/.eta_par.objs/public_cmi"
tmp_dir="${TMPDIR:-/tmp}/eta-island-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmx"

  if ocamlfind ocamlopt -extension-universe alpha \
      -package "eio,eio_main,portable,unix,threads" \
      -I "$cmi_dir" -I "$obj_dir" -I "$par_cmi_dir" -I "$par_obj_dir" \
      -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eq "portable|shareable|contended|local|mode" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

exit "$status"
