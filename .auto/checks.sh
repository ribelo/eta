#!/usr/bin/env bash
# Correctness gate for the H2-latency autoresearch loop. Runs the eta-http
# H2 server/client/HPACK/multiplexer unit suites in the release profile, so any
# latency optimization that breaks HPACK decode, framing, or H2 protocol
# behavior fails and the candidate is reverted.
#
# Heavier conformance/interop suites (@h2spec, @interop, @cve-regress) are NOT
# run per iteration — run them at finalize / before merge.
set -euo pipefail

cd "$(dirname "$0")/.."
export EIO_BACKEND="${EIO_BACKEND:-posix}"

nix develop -c dune runtest --profile release test/http_eio test/http_common 2>&1 | tail -40
