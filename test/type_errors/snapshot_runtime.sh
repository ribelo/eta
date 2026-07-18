#!/usr/bin/env bash
# Build and run the cross-domain misuse probes, concatenating their output.
# Invoked by the dune rule in this directory with $1 = project root; cwd is
# the dune build dir. Every scenario is wrapped in `timeout` because the
# blocking-pair scenario's expected outcome is a hang.
set -uo pipefail
# Dune sets DUNE_SOURCEROOT and INSIDE_DUNE (absolute source/build roots) in
# rule actions; fall back to resolving $1 for manual runs.
ROOT="${DUNE_SOURCEROOT:-$(cd "$1" && pwd)}"
B="${INSIDE_DUNE:-$ROOT/_build/default}"
mkdir -p _probe_build
ocamlfind ocamlopt -thread -package eio_main,eio.unix,unix,threads.posix -linkpkg \
  -I "$B/lib/eta/.eta.objs/byte" -I "$B/lib/eta/.eta.objs/native" \
  -I "$B/lib/blocking/.eta_blocking.objs/byte" -I "$B/lib/blocking/.eta_blocking.objs/native" \
  -I "$B/lib/eio/.eta_eio.objs/byte" -I "$B/lib/eio/.eta_eio.objs/native" \
  -I "$B/lib/par/.eta_par.objs/byte" -I "$B/lib/par/.eta_par.objs/native" \
  "$B/lib/eta/eta.cmxa" "$B/lib/blocking/eta_blocking.cmxa" \
  "$B/lib/eio/eta_eio.cmxa" "$B/lib/par/eta_par.cmxa" \
  cases_runtime/cross_domain_channel.ml -o _probe_build/probe 2>&1
echo "build exit=$?"
rm -f cases_runtime/cross_domain_channel.cmi cases_runtime/cross_domain_channel.cmx cases_runtime/cross_domain_channel.o

for scenario in try-send queue-contrast blocking-pair; do
  echo "===== $scenario ====="
  EIO_BACKEND=posix timeout 12 ./_probe_build/probe "$scenario" 2>&1
  echo "exit=$?"
done
