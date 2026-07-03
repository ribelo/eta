#!/usr/bin/env bash
set -u

eta_signal_cma="$1"
eta_signal_dir="$(dirname "$eta_signal_cma")"
build_root="$eta_signal_dir/../.."
fixture_dir="$(dirname "$0")"
tmp_dir="${TMPDIR:-/tmp}/eta-signal-negative-$$"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

status=0

compile_fixture() {
  local src="$1"
  local obj="$2"
  local log="$3"

  ocamlfind ocamlc \
    -I "$build_root/lib/eta/.eta.objs/byte" \
    -I "$build_root/lib/stream/.eta_stream.objs/byte" \
    -I "$eta_signal_dir/.eta_signal.objs/byte" \
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
  case "$name" in
    cross_graph_signal_negative.ml)
      expected='type "?int A\.signal"?|expected of type "?int B\.signal"?'
      ;;
    computed_negative.ml)
      expected='Unbound value "?Signal\.computed"?'
      ;;
    global_graph_negative.ml)
      expected='Unbound module "?Eta_signal\.Var"?'
      ;;
    first_class_graph_negative.ml)
      expected='Unbound module "?Signal\.Graph"?'
      ;;
    raw_signal_read_negative.ml)
      expected='Unbound value "?Signal\.read"?'
      ;;
    derived_signal_delete_negative.ml)
      expected='Unbound value "?Signal\.dispose"?'
      ;;
    public_batch_negative.ml)
      expected='Unbound value "?Signal\.batch"?'
      ;;
    public_expert_negative.ml)
      expected='Unbound module "?Signal\.Expert"?'
      ;;
    private_test_hooks_negative.ml)
      expected='Unbound module "?Signal\.Private_test_hooks"?'
      ;;
    public_scope_negative.ml)
      expected='Unbound module "?Signal\.Scope"?'
      ;;
    map10_negative.ml)
      expected='Unbound value "?Signal\.map10"?'
      ;;
    map_mutation_value_negative.ml)
      expected='Eta\.Effect\.t Signal\.signal|expected of type "int Signal\.signal"'
      ;;
    observer_read_error_negative.ml)
      expected='Signal\.observer_read_error|Signal\.graph_error|does not allow tag'
      ;;
    stream_to_signal_negative.ml)
      expected='Unbound value "?Signal\.Stream\.to_signal"?'
      ;;
    time_constructor_effectful_negative.ml)
      expected='Signal\.time_error.*Eta\.Effect\.t|expected of type "int Signal\.signal"'
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
  elif ! grep -Eiq "$expected" "$log"; then
    echo "fixture failed for the wrong reason: $name"
    sed -n '1,120p' "$log"
    status=1
  fi
done

exit "$status"
