#!/usr/bin/env bash
set -u

eta_signal_cma="$1"
eta_signal_dir="$(dirname "$eta_signal_cma")"
build_root="$eta_signal_dir/../.."
fixture_dir="$(dirname "$0")"
tmp_dir="${TMPDIR:-/tmp}/eta-signal-negative-$$"
mkdir -p "$tmp_dir"

status=0

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"
  case "$name" in
    cross_graph_signal_negative.ml)
      expected='A\.signal|B\.signal|expression was expected of type.*signal|This expression has type.*signal'
      ;;
    raw_signal_read_negative.ml)
      expected='Unbound value "?Signal\.read"?|Unbound value "?read"?'
      ;;
    public_batch_negative.ml)
      expected='Unbound value "?Signal\.batch"?|Unbound value "?batch"?'
      ;;
    *)
      echo "no expected failure pattern configured for: $name"
      status=1
      continue
      ;;
  esac

  if ocamlfind ocamlc \
      -I "$build_root/lib/eta/.eta.objs/byte" \
      -I "$build_root/lib/stream/.eta_stream.objs/byte" \
      -I "$eta_signal_dir/.eta_signal.objs/byte" \
      -c "$src" -o "$obj" >"$log" 2>&1; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! grep -Eiq "$expected" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

rm -rf "$tmp_dir"
exit "$status"
