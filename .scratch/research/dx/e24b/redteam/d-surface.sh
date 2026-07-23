#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
baseline_ref=28d29f4a1f4487ad7e7c6032a505d924b31c6296
test "$(git show -s --format=%s "$baseline_ref")" = \
  'docs(dx-e24b): seal predictions'

mapfile -t baseline_taps < <(
  git grep -n -E '\|> (Eta\.)?Schedule\.tap_(input|output)' \
    "$baseline_ref" -- test
)
baseline_tap_files=$(
  printf '%s\n' "${baseline_taps[@]}" | cut -d: -f2 | sort -u | wc -l
)

tap_vals=$(grep -Ec '^val tap_(input|output)' lib/eta/schedule.mli || true)
hook_constructors=$(grep -Ec '^  \| Hook of' lib/eta/schedule.mli || true)
suspended_entry_points=$(
  grep -Ec '^val (step_plan|step_with_hooks)' lib/eta/schedule.mli || true
)
documented_tap_promises=$(
  git grep -E \
    'Schedule taps|[Ss]chedule tap failures|Effectful schedule taps' \
    -- 'lib/**/*.mli' | wc -l
)
effect_signatures=$(grep -Ec 'Schedule\.t ->' lib/eta/effect.mli || true)
resource_signatures=$(grep -Ec 'Schedule\.t ->' lib/eta/resource.mli || true)
stream_signatures=$(grep -Ec 'Eta\.Schedule\.t ->' lib/stream/eta_stream.mli || true)
http_no_hook=$(
  grep -Ec 'Eta\.Schedule\.no_hook\) Eta\.Schedule\.t ->' \
    lib/http/client/retry.mli || true
)
http_internal_no_hook=$(
  grep -Ec 'Eta\.Schedule\.no_hook\) Eta\.Schedule\.t' \
    lib/http/client/retry.ml || true
)
interpreters=$(
  { grep -Ec 'Sch\.step_with_hooks' lib/eta/effect_schedule.ml || true; } \
    | awk '{ total += $1 } END { print total }'
)
interpreters=$((
  interpreters
  + $(grep -Ec 'Schedule\.step_plan' lib/eta/resource.ml || true)
  + $(grep -Ec 'Eta\.Schedule\.step_plan' lib/stream/eta_stream.ml || true)
))
js_reexports=$(
  git grep -E 'module Schedule = Eta\.Schedule' -- lib/js/eta_js.ml \
    lib/js/eta_js.mli | wc -l
)

test "${#baseline_taps[@]}" -eq 12
test "$baseline_tap_files" -eq 4
test "$tap_vals" -eq 2
test "$hook_constructors" -eq 1
test "$suspended_entry_points" -eq 2
test "$documented_tap_promises" -eq 6
test "$effect_signatures" -eq 3
test "$resource_signatures" -eq 1
test "$stream_signatures" -eq 4
test "$http_no_hook" -eq 2
test "$http_internal_no_hook" -eq 1
test "$interpreters" -eq 3
test "$js_reexports" -eq 2
if git grep -n -E '(Eta\.)?Schedule\.tap_(input|output)' -- lib; then
  echo 'unexpected shipped tap producer' >&2
  exit 1
fi

cat <<EOF
D deletion surface (asserted current/baseline facts):
- 12 pre-E24b tap constructions in 4 test files stop compiling
- 2 public tap constructors disappear
- 1 public Hook constructor and 2 suspended stepping entry points disappear
- 8 effectful operation signatures change from 3 Schedule.t parameters to 2
- 2 explicit HTTP no_hook signatures and 1 internal packed_schedule lose the marker
- 6 explicit public tap-behavior promises across Effect, Resource, and Stream must be removed or replaced
- 3 production hook interpreters become unnecessary
- 0 shipped tap producers exist; Eta_js has 1 implementation/interface re-export pair
EOF
