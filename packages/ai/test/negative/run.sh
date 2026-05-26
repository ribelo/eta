#!/usr/bin/env bash
set -u

eta_ai_cma="$1"
eta_ai_dir="$(dirname "$eta_ai_cma")"
build_root="$eta_ai_dir/../.."
fixture_dir="$(dirname "$0")"
tmp_dir="${TMPDIR:-/tmp}/eta-ai-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"

  if ocamlfind ocamlc -extension-universe alpha \
      -package "eio,eio_main,portable,threads" \
      -I "$eta_ai_dir/.ai.objs/byte" \
      -I "$build_root/packages/par/.par.objs/byte" \
      -I "$build_root/packages/eta/.eta.objs/byte" \
      -I "$build_root/packages/redacted/.redacted.objs/byte" \
      -I "$build_root/packages/http/.http.objs/byte" \
      -I "$build_root/packages/http/core/.http_core.objs/byte" \
      -I "$build_root/packages/http/body/.http_body.objs/byte" \
      -I "$build_root/packages/http/client/.http_client.objs/byte" \
      -I "$build_root/packages/http/error/.http_error.objs/byte" \
      -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eiq 'Ai\.api_key|string Redacted\.t|expected of type "?string"?' "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

rm -rf "$tmp_dir"
exit "$status"
