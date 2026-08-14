#!/usr/bin/env bash

set -u

bundle_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$bundle_dir/../../../.." && pwd)"
probe_dir="$bundle_dir/probes"
result_dir="$bundle_dir/results"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$result_dir"
rm -f "$result_dir"/*.txt

{
  printf '$ command -v ocamlc\n'
  command -v ocamlc
  printf '\n$ ocamlc -version\n'
  ocamlc -version
  printf '\n$ ocamlc -config | sed '\''s/[[:space:]]*$//'\''\n'
  ocamlc -config | sed 's/[[:space:]]*$//'
  printf '\n$ uname -m\n'
  uname -m
  printf '\n$ pinned OxCaml revision from flake.lock\n'
  python3 -c \
    'import json, sys; print(json.load(open(sys.argv[1]))["nodes"]["oxcaml"]["locked"]["rev"])' \
    "$repo_dir/flake.lock"
} >"$result_dir/toolchain.txt" 2>&1

failures=0

run_probe() {
  name="$1"
  expected="$2"
  source="$probe_dir/$name.ml"
  output="$work_dir/$name.output"
  result="$result_dir/$name.txt"

  cp "$source" "$work_dir/$name.ml"

  (
    cd "$work_dir"
    ocamlc -c "$name.ml"
  ) >"$output" 2>&1
  actual=$?

  if [ "$actual" -eq "$expected" ]; then
    verdict=pass
  else
    verdict=FAIL
    failures=$((failures + 1))
  fi

  {
    printf 'command: ocamlc -c %s.ml\n' "$name"
    printf 'expected exit: %s\n' "$expected"
    printf 'actual exit: %s\n' "$actual"
    printf 'verdict: %s\n' "$verdict"
    printf '%s\n' '--- compiler output ---'
    cat "$output"
  } >"$result"

  printf '%-24s expected=%s actual=%s %s\n' \
    "$name" "$expected" "$actual" "$verdict"
}

run_probe positive 0
run_probe affine_drop 0
run_probe local_escape 2
run_probe nonportable_closure 2
run_probe contended_mutation 2
run_probe unique_twice 2
run_probe once_twice 2
run_probe capsule_unavailable 2

if [ "$failures" -ne 0 ]; then
  printf '%s probe result(s) did not match.\n' "$failures" >&2
  exit 1
fi

printf 'All probe results matched.\n'
