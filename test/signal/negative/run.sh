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
    computed_negative.ml)
      expected='Unbound value "?Signal\.computed"?|Unbound value "?computed"?'
      ;;
    global_graph_negative.ml)
      expected='Unbound module "?Eta_signal\.Var"?|Unbound value "?Eta_signal\.Var'
      ;;
    first_class_graph_negative.ml)
      expected='Unbound module "?Signal\.Graph"?|Unbound value "?Signal\.Graph'
      ;;
    raw_signal_read_negative.ml)
      expected='Unbound value "?Signal\.read"?|Unbound value "?read"?'
      ;;
    derived_signal_delete_negative.ml)
      expected='Unbound value "?Signal\.dispose"?|Unbound value "?dispose"?'
      ;;
    public_batch_negative.ml)
      expected='Unbound value "?Signal\.batch"?|Unbound value "?batch"?'
      ;;
    public_expert_negative.ml)
      expected='Unbound module "?Signal\.Expert"?|Unbound value "?Signal\.Expert'
      ;;
    private_test_hooks_negative.ml)
      expected='Unbound module "?Signal\.Private_test_hooks"?|Unbound value "?Signal\.Private_test_hooks'
      ;;
    public_scope_negative.ml)
      expected='Unbound module "?Signal\.Scope"?|Unbound value "?Signal\.Scope'
      ;;
    map10_negative.ml)
      expected='Unbound value "?Signal\.map10"?|Unbound value "?map10"?'
      ;;
    map_mutation_value_negative.ml)
      expected='Eta\.Effect\.t|Effect\.t|but an expression was expected of type.*int Signal\.signal|This expression has type.*Effect'
      ;;
    observer_read_error_negative.ml)
      expected='observer_read_error|graph_error|The second variant type does not allow tag|This expression has type.*Observer\.read'
      ;;
    stream_to_signal_negative.ml)
      expected='Unbound value "?Signal\.Stream\.to_signal"?|Unbound value "?to_signal"?'
      ;;
    time_constructor_effectful_negative.ml)
      expected='Eta\.Effect\.t|Effect\.t|but an expression was expected of type.*Signal\.signal|This expression has type.*Effect'
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
