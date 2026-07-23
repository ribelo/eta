#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
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
count 2 'Eta\.Schedule\.t ->' lib/http/client/retry.mli

if rg -n 'Schedule\.no_hook|Schedule\.(tap_input|tap_output|step_plan|step_with_hooks)' \
    lib test --glob '!test/type_errors/**'; then
  echo 'legacy schedule-hook surface remains' >&2
  exit 1
fi

cat <<'EOF'
post-E24c two-parameter external operations=8 (Effect 3 + Resource 1 + Stream 4)
post-E24c two-parameter HTTP signatures=2
post-E24c legacy schedule-hook references in lib/test=0
EOF
