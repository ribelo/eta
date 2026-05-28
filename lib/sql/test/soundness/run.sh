#!/usr/bin/env bash
set -u

cmxa="$1"
fixture_dir="$(dirname "$0")"
sql_obj_dir="$(dirname "$cmxa")/.eta_sql.objs/byte"
eta_obj_dir="$(dirname "$cmxa")/../eta/.eta.objs/byte"
par_obj_dir="$(dirname "$cmxa")/../par/.par.objs/byte"
tmp_dir="${TMPDIR:-/tmp}/eta-sql-soundness-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmx"

  if ocamlfind ocamlopt -extension-universe alpha \
      -package "eio,eio_main,portable,unix,threads" \
      -I "$par_obj_dir" -I "$eta_obj_dir" -I "$sql_obj_dir" \
      -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eiq "type|expected|but|unify|compatible|constructor" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

rm -rf "$tmp_dir"
exit "$status"
