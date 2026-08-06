#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$PWD/.selected_factory_owner.objs" ]]; then
  root="$PWD"
  build="$root"
else
  root="$script_root"
  build="$root/_build/default"
fi
tmp="${TMPDIR:-/tmp}/eta-finalist-negative-$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"

includes=(
  -I "$build/.selected_factory_owner.objs/byte"
  -I "$build/.finalist_probe_support.objs/byte"
  -I "$build"
)
if [[ -n "${ETA_REPO:-}" ]]; then
  includes+=(
    -I "$ETA_REPO/_build/default/lib/eta/.eta.objs/byte"
    -I "$ETA_REPO/_build/default/lib/stream/.eta_stream.objs/byte"
    -I "$ETA_REPO/_build/default/lib/signal/.eta_signal.objs/byte"
    -I "$ETA_REPO/_build/default/lib/signal/engine/.eta_signal_engine.objs/byte"
    -I "$ETA_REPO/_build/default/lib/signal_stream/.eta_signal_stream.objs/byte"
    -I "$ETA_REPO/_build/default/lib/signal_map/.eta_signal_map.objs/byte"
  )
fi
for pkg in eta eta_signal eta_signal_map eta_signal_stream eta_stream; do
  includes+=(-I "$(ocamlfind query "$pkg")")
done

compile_fixture() {
  local src="$1" obj="$2" log="$3"
  local selected=()
  local index path
  for ((index = 0; index < ${#includes[@]}; index += 2)); do
    path="${includes[index + 1]}"
    case "$(basename "$src"):$path" in
      private_transaction_negative.ml:*signal/engine*) ;;
      private_kernel_negative.ml:*signal/engine*) ;;
      *) selected+=(-I "$path") ;;
    esac
  done
  ocamlfind ocamlc "${selected[@]}" -c "$src" -o "$obj" >"$log" 2>&1
}

status=0
for dir in "$root/generated/negative-signal" "$root/generated/negative-map"; do
  for src in "$dir"/*_positive.ml; do
    name="$(basename "$src")"
    if ! compile_fixture "$src" "$tmp/${name%.ml}.cmo" "$tmp/$name.log"; then
      echo "negative suite: expected positive fixture to compile: $name"
      sed -n '1,120p' "$tmp/$name.log"
      status=1
    fi
  done
  for src in "$dir"/*_negative.ml; do
    name="$(basename "$src")"
    if compile_fixture "$src" "$tmp/${name%.ml}.cmo" "$tmp/$name.log"; then
      echo "negative suite: expected compile rejection: $name"
      status=1
    elif grep -Eqi 'Unbound module Selected_factory_fresh|inconsistent assumptions' "$tmp/$name.log"; then
      echo "negative suite: fixture rejected before reaching its public fence: $name"
      sed -n '1,120p' "$tmp/$name.log"
      status=1
    fi
  done
done
exit "$status"
