#!/usr/bin/env bash
set -u

eta_crux_cma="$1"
eta_crux_dir="$(dirname "$eta_crux_cma")"
build_root="$eta_crux_dir/../.."
fixture_dir="$(dirname "$0")"
tmp_dir="${TMPDIR:-/tmp}/eta-crux-negative-$$"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

status=0

compile_fixture() {
  local src="$1"
  local obj="$2"
  local log="$3"

  ocamlfind ocamlc \
    -I "$build_root/lib/eta/.eta.objs/byte" \
    -I "$eta_crux_dir/.eta_crux.objs/byte" \
    -c "$src" -o "$obj" >"$log" 2>&1
}

log_contains_all() {
  local log="$1"
  shift
  local normalized="$log.normalized"
  tr -d '"' <"$log" >"$normalized"
  for expected in "$@"; do
    if ! grep -Fqi "$expected" "$normalized"; then
      return 1
    fi
  done
}

for src in "$fixture_dir"/*_negative.ml; do
  name="$(basename "$src")"
  log="$tmp_dir/$name.log"
  obj="$tmp_dir/${name%.ml}.cmo"
  case "$name" in
    root_is_not_description_negative.ml)
      expected=('Root.t' 'Eta_crux.t')
      ;;
    staged_effect_rejects_typed_error_negative.ml)
      expected=('Application_error' 'Eta_crux.never')
      ;;
    admission_must_be_handled_negative.ml)
      expected=('Endpoint.admission_error' 'Eta_crux.never')
      ;;
    *)
      echo "no expected failure pattern configured for: $name"
      status=1
      continue
      ;;
  esac

  if compile_fixture "$src" "$obj" "$log"; then
    echo "expected compile failure, but fixture compiled: $name"
    status=1
  elif ! log_contains_all "$log" "${expected[@]}"; then
    echo "fixture failed for the wrong reason: $name"
    printf '  - %s\n' "${expected[@]}"
    sed -n '1,100p' "$log"
    status=1
  fi
done

exit "$status"
