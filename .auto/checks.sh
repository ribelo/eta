#!/usr/bin/env bash
# Correctness gate for the H2-TLS-latency autoresearch loop. Runs the eta-http
# H1+H2 server/client unit suites + shared HTTP suites in the release profile
# (test/http_eio includes the h2-multiplexer + hpack suites), so any latency
# optimization that breaks H1/H2 framing, keep-alive, chunked encoding, flow
# control, or request/response handling fails and the candidate is reverted.
#
# Heavier conformance/interop suites are NOT run per iteration - run them at
# finalize / before merge.
set -euo pipefail

cd "$(dirname "$0")/.."
export EIO_BACKEND="${EIO_BACKEND:-posix}"

nix develop -c dune runtest --profile release test/http_eio test/http_common 2>&1 | tail -40
