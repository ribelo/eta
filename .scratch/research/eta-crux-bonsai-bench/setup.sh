#!/usr/bin/env bash
set -euo pipefail

bundle_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$bundle_dir/../../.." && pwd)"
switch_dir="${ETA_CRUX_BONSAI_SWITCH:-$repo_dir/.scratch/eta-crux-bonsai-switch}"
eta_build_dir="$repo_dir/.scratch/eta-crux-bonsai-build/eta"
bench_build_dir="$repo_dir/.scratch/eta-crux-bonsai-build/bench"
compiler="5.2.0minus38"
bonsai_version="v0.18~preview.130.100+614"
ox_repository_commit="d65f081024758576f7a848bbd369863e7f7c1e81"
ox_repository_name="eta-crux-bonsai-ox"

mkdir -p "$switch_dir" "$(dirname "$eta_build_dir")"

if ! opam switch list --short | grep -Fxq "$switch_dir"; then
  opam switch create "$switch_dir" --empty -y
fi
if ! opam repository list --switch "$switch_dir" --short |
     grep -Fxq "$ox_repository_name"; then
  opam repository add --switch "$switch_dir" \
    "$ox_repository_name" \
    "git+https://github.com/oxcaml/opam-repository.git#$ox_repository_commit" \
    -y
fi
actual_ox_repository_commit="$(
  git -C "$(opam var root)/repo/$ox_repository_name" rev-parse HEAD
)"
if [[ "$actual_ox_repository_commit" != "$ox_repository_commit" ]]; then
  echo "unexpected Ox opam repository commit: $actual_ox_repository_commit" >&2
  exit 1
fi

installed_compiler="$(
  opam show --switch "$switch_dir" oxcaml-compiler \
    --field=installed-version 2>/dev/null || true
)"
if [[ "$installed_compiler" != "$compiler" ]]; then
  opam install --switch "$switch_dir" \
    "ocaml-variants.5.2.0+ox" "oxcaml-compiler.$compiler" \
    --assume-depexts -y
fi

eval "$(opam env --switch "$switch_dir" --set-switch)"
switch_prefix="$(opam var --switch "$switch_dir" prefix)"

opam install --assume-depexts -y \
  "bonsai=$bonsai_version" \
  cstruct eio eio_main eio_posix mtime
command -v opam-installer >/dev/null ||
  { echo "opam-installer is required" >&2; exit 1; }

dune build --root "$repo_dir" --build-dir "$eta_build_dir" \
  --profile release \
  eta.install \
  eta_blocking.install \
  eta_crux.install \
  eta_eio.install \
  eta_observability.install \
  eta_signal.install \
  eta_signal_map.install

(
  cd /
  for package in \
    eta \
    eta_blocking \
    eta_crux \
    eta_eio \
    eta_observability \
    eta_signal \
    eta_signal_map
  do
    opam-installer --prefix "$switch_prefix" \
      "$eta_build_dir/default/$package.install" >/dev/null
  done
)

dune build --root "$bundle_dir" --build-dir "$bench_build_dir" \
  --profile release \
  eta_adapter.exe bonsai_adapter.exe

printf 'switch=%s\n' "$switch_dir"
printf 'eta_adapter=%s/default/eta_adapter.exe\n' "$bench_build_dir"
printf 'bonsai_adapter=%s/default/bonsai_adapter.exe\n' "$bench_build_dir"
