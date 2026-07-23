#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

count() {
  local expected=$1 pattern=$2 file=$3 actual
  actual=$(grep -Ec "$pattern" "$file" || true)
  test "$actual" -eq "$expected" || {
    printf 'census drift: %s expected %s, found %s\n' "$file" "$expected" "$actual" >&2
    exit 1
  }
}

count 0 '^val tap_(input|output)' lib/eta/schedule.mli
count 0 '^  \| Hook of' lib/eta/schedule.mli
count 0 '^val (step_plan|step_with_hooks)' lib/eta/schedule.mli
count 3 'Schedule\.t ->' lib/eta/effect.mli
count 1 'Schedule\.t ->' lib/eta/resource.mli
count 4 'Eta\.Schedule\.t ->' lib/stream/eta_stream.mli
count 2 'Eta\.Schedule\.t ->' lib/http/client/retry.mli

if rg -n 'Schedule\.no_hook|Schedule\.(tap_input|tap_output|step_plan|step_with_hooks)' \
    lib test --glob '!test/type_errors/**'; then
  echo 'legacy schedule-hook surface remains' >&2
  exit 1
fi

test "$(git grep -E 'module Schedule = Eta\.Schedule' -- \
  lib/js/eta_js.ml lib/js/eta_js.mli | wc -l)" -eq 2

cat <<OUT
D deletion surface (asserted post-E24c facts):
- 0 public tap constructors, Hook constructors, or suspended stepping entry points
- 8 effectful operation signatures use two-parameter Schedule.t
- 2 HTTP signatures use two-parameter Schedule.t; no no_hook marker remains
- 0 legacy schedule-hook references in lib/test
- Eta_js keeps its implementation/interface re-export pair
OUT
