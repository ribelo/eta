#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
baseline_ref=28d29f4a1f4487ad7e7c6032a505d924b31c6296
test "$(git show -s --format=%s "$baseline_ref")" = \
  'docs(dx-e24b): seal predictions'

count() {
  local expected=$1
  local pattern=$2
  local file=$3
  local actual
  actual=$(grep -Ec "$pattern" "$file" || true)
  if [[ "$actual" != "$expected" ]]; then
    printf 'census drift: %s expected %s, found %s\n' "$file" "$expected" "$actual" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$file" "$actual" "$pattern"
}

printf '%s\n' '-- public external Schedule.t signatures --'
count 3 'Schedule\.t ->' lib/eta/effect.mli
count 1 'Schedule\.t ->' lib/eta/resource.mli
count 4 'Eta\.Schedule\.t ->' lib/stream/eta_stream.mli
count 2 'Eta\.Schedule\.no_hook\) Eta\.Schedule\.t ->' lib/http/client/retry.mli

printf '%s\n' '-- production interpretation seams --'
count 1 'Sch\.step_with_hooks' lib/eta/effect_schedule.ml
count 1 'Schedule\.step_plan' lib/eta/resource.ml
count 1 'Eta\.Schedule\.step_plan' lib/stream/eta_stream.ml

printf '%s\n' '-- tap constructor census (tests only) --'
mapfile -t baseline_tap_calls < <(
  git grep -n -E '\|> (Eta\.)?Schedule\.tap_(input|output)' \
    "$baseline_ref" -- test
)
baseline_tap_files=$(
  printf '%s\n' "${baseline_tap_calls[@]}" \
    | cut -d: -f2 | sort -u | wc -l
)
test "${#baseline_tap_calls[@]}" -eq 12
test "$baseline_tap_files" -eq 4
printf 'pre-E24b tap constructor calls=%d files=%d\n' \
  "${#baseline_tap_calls[@]}" "$baseline_tap_files"

mapfile -t current_tap_calls < <(
  rg -n --glob '*.{ml,mli}' '\|> (Eta\.)?Schedule\.tap_(input|output)' test
)
current_tap_files=$(
  printf '%s\n' "${current_tap_calls[@]}" | cut -d: -f1 | sort -u | wc -l
)
test "${#current_tap_calls[@]}" -eq 25
test "$current_tap_files" -eq 4
printf 'post-follow-up tap constructor calls=%d files=%d\n' \
  "${#current_tap_calls[@]}" "$current_tap_files"

cat <<'EOF'
current hook-accepting external operations=8 (Effect 3 + Resource 1 + Stream 4)
current explicit no-hook external signatures=2 (HTTP retry entry points)
strongest shared-record B minimum=1 observer type with pre/post fields + 8 driver labels/contracts
per-callback B spelling=16 callback labels/contracts across those 8 operations
current production interpreters=3 helpers serving 3 + 1 + 4 operations
EOF
