#!/usr/bin/env bash
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$root" rev-parse --show-toplevel)"
mode="${1:-tests}"
cpu="${CPU:-2}"
build_timeout="${BUILD_TIMEOUT:-180s}"
suite_timeout="${SUITE_TIMEOUT:-120s}"
build="$root/_build/default"
status=0
export ETA_REPO="$repo"
export OCAMLPATH="$root/_install/lib${OCAMLPATH:+:$OCAMLPATH}"

install_inputs() {
  timeout "$build_timeout" dune build --root "$repo" @install &&
    timeout "$build_timeout" dune install --root "$repo" --prefix "$root/_install" \
      eta eta_blocking eta_observability eta_stream eta_eio eta_signal \
      eta_signal_map eta_signal_stream eta_test
}

generate() {
  python3 "$root/generate.py" || return
  python3 "$root/check_generated.py"
}

run_suite() {
  local suite="$1" target="$2"
  echo "=== suite: $suite"
  if timeout "$build_timeout" dune build --root "$root" --profile release "$target"; then
    if timeout "$suite_timeout" env EIO_BACKEND=posix "$build/$target"; then
      echo "PASS: $suite"
    else
      echo "FAIL(runtime): $suite"
      status=1
    fi
  else
    echo "FAIL(compile): $suite"
    status=1
  fi
}

run_tests() {
  install_inputs && generate || { status=1; return; }
  local suites=(
    "selected-core:selected_core_check.exe"
    "selected-edges:selected_edges_check.exe"
    "signal-public:test_eta_signal_public.exe"
    "signal-contract:test_eta_signal_contract.exe"
    "signal-model:test_eta_signal_model.exe"
    "signal-lifecycle-and-timer:test_eta_signal.exe"
    "signal-stream:test_eta_signal_stream.exe"
    "signal-map:test_eta_signal_map.exe"
    "signal-map-keyed:test_eta_signal_map_keyed.exe"
    "signal-laws:signal_properties.exe"
    "finalist-native-replacements:finalist_native_checks.exe"
  )
  local entry
  for entry in "${suites[@]}"; do
    run_suite "${entry%%:*}" "${entry#*:}"
  done
  echo "=== suite: negative-compile"
  if timeout "$build_timeout" dune build --root "$root" --profile release @negative; then
    echo "PASS: negative-compile"
  else
    echo "FAIL: negative-compile"
    status=1
  fi
}

record() {
  local pair="$1" boundary="$2" side="$3" canonical="$4" exe="$5" selected="$6"
  local captured
  captured="$(mktemp)"
  if ! taskset -c "$cpu" "$exe" --only "$selected" >"$captured"; then
    echo "FAIL(performance): pair=$pair boundary=$boundary side=$side workload=$canonical" >&2
    rm -f "$captured"
    status=1
    return
  fi
  awk -F, -v OFS=, -v pair="$pair" -v boundary="$boundary" \
      -v side="$side" -v canonical="$canonical" \
      'NR > 1 { print pair,boundary,side,canonical,$2,$3,$4,$5 }' \
      "$captured" >>"$results"
  rm -f "$captured"
}

run_performance() {
  install_inputs && generate || { status=1; return; }
  if ! dune build --root "$root" --profile release compare_public.exe compare_raw.exe; then
    status=1
    return
  fi
  mkdir -p "$root/results"
  results="$root/results/raw.csv"
  echo "pair,boundary,side,workload,operations,sample,wall_ns,allocated_words" >"$results"
  local pair canonical reference public raw
  for pair in 1 2 3; do
    while IFS=$'\t' read -r canonical reference public raw; do
      [[ -z "$canonical" || "$canonical" == \#* ]] && continue
      # Every command is a fresh process pinned to the same CPU. Each executable
      # calibrates from one operation and emits exactly nine measured samples.
      record "$pair" raw reference "$canonical" "$build/compare_public.exe" "$reference"
      record "$pair" raw finalist "$canonical" "$build/compare_raw.exe" "$raw"
      record "$pair" public reference "$canonical" "$build/compare_public.exe" "$reference"
      record "$pair" public finalist "$canonical" "$build/compare_public.exe" "$public"
    done <"$root/performance-workloads.tsv"
  done
  python3 "$root/summarize.py" "$results" "$root/results/summary.csv"
  echo "wrote $results"
  echo "wrote $root/results/summary.csv"
}

run_raw_smoke() {
  local selection="${1:-all}"
  install_inputs && generate || { status=1; return; }
  mkdir -p "$root/results"
  if [[ "$selection" == keyed ]]; then
    results="$root/results/raw-keyed-smoke.tsv"
  else
    results="$root/results/raw-smoke.tsv"
  fi
  printf 'pair\tworkload\tside\tcorrectness\toperations\tsample\twall_ns\tallocated_words\tfirst_failure\n' >"$results"
  if ! dune build --root "$root" --profile release compare_raw.exe ||
     ! dune build --root "$repo" --profile release bench/signal_compare/compare.exe; then
    printf '1\t*\tcompile\tfailure\t\t\t\t\traw smoke executables failed to compile\n' >>"$results"
    status=1
    echo "wrote $results"
    return
  fi
  local canonical reference public raw captured failure fields allocation ceiling relation
  local wall reference_wall
  while IFS=$'\t' read -r canonical reference public raw; do
    [[ -z "$canonical" || "$canonical" == \#* ]] && continue
    [[ "$selection" == keyed && "$raw" != map.* ]] && continue
    for side in reference finalist; do
      captured="$(mktemp)"
      if [[ "$side" == reference ]]; then
        exe="$repo/_build/default/bench/signal_compare/compare.exe"
        selected="$reference"
      else
        exe="$build/compare_raw.exe"
        selected="$raw"
      fi
      if taskset -c "$cpu" "$exe" --only "$selected" --samples 1 \
           >"$captured" 2>"$captured.err"; then
        fields="$(awk -F, 'NR == 2 { print $2"\t"$3"\t"$4"\t"$5 }' "$captured")"
        wall="$(printf '%s\n' "$fields" | cut -f3)"
        failure=""
        if [[ "$side" == reference ]]; then
          reference_wall="$wall"
        else
          allocation="$(printf '%s\n' "$fields" | cut -f4)"
          relation="at most"
          case "$raw" in
            changed.*|cutoff.*) ceiling=100; relation="fewer than" ;;
            dynamic.switch) ceiling=51.6 ;;
            map.data_change.10000) ceiling=216 ;;
            map.data_change.100000) ceiling=273.6 ;;
            map.membership_change.10000) ceiling=412.2 ;;
            map.membership_change.100000) ceiling=520.2 ;;
            map.child_change.10000) ceiling=93.6 ;;
            map.child_change.100000) ceiling=122.4 ;;
          esac
          if ! awk -v value="$allocation" -v ceiling="$ceiling" \
               -v relation="$relation" \
               'BEGIN { if (relation == "fewer than") exit !(value < ceiling); else exit !(value <= ceiling) }'; then
            failure="allocation $allocation words; requires $relation $ceiling"
          fi
          if [[ -z "$failure" ]] &&
             ! awk -v candidate="$wall" -v reference="$reference_wall" \
               'BEGIN { exit !(candidate <= 1.20 * reference) }'; then
            failure="wall $wall ns exceeds 1.20 x reference $reference_wall ns"
          fi
          if [[ -n "$failure" ]]; then status=1; fi
        fi
        printf '1\t%s\t%s\tpass\t%s\t%s\n' \
          "$raw" "$side" "$fields" "$failure" >>"$results"
      else
        failure="$(head -n 1 "$captured.err" | tr '\t\r\n' '   ')"
        printf '1\t%s\t%s\tfailure\t\t\t\t\t%s\n' \
          "$raw" "$side" "$failure" >>"$results"
        status=1
      fi
      rm -f "$captured" "$captured.err"
    done
  done <"$root/performance-workloads.tsv"
  echo "wrote $results"
}

case "$mode" in
  tests) run_tests ;;
  raw-smoke) run_raw_smoke ;;
  raw-keyed-smoke) run_raw_smoke keyed ;;
  performance) run_performance ;;
  all) run_tests; run_performance ;;
  *) echo "usage: $0 [tests|raw-smoke|raw-keyed-smoke|performance|all]" >&2; exit 2 ;;
esac
exit "$status"
