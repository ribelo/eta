# H-Q4a Scripted Fixture Interop

Status: Closed with documented coverage boundaries.

## Hypothesis

eta-http interop can be demonstrated with scripted fixtures against real
implementations: curl, nghttp2/nghttpd, nginx, and Caddy.

## Harness

The historical `scripts/run_matrix.sh` lab starts local nginx, Caddy, and
nghttpd instances from the Nix dev shell, generates a temporary self-signed
certificate, creates a sparse 100MB body fixture, and runs curl, nghttp2, and
eta-http probes against the servers.

The script writes raw `results.tsv` under local `.scratch`; the durable tracked
summary is `results.md`.

## Reproduce

    nix develop -c bash .scratch/research/evidence/eta_http_research/h_q4a_interop_matrix/scripts/run_matrix.sh

The Nix shell supplies curl, nghttp2/nghttpd, nginx, Caddy, and OpenSSL through
flake.nix.

## Coverage Boundaries

The harness covers the eta-http-supported client paths: HTTP/1.1, HTTPS ALPN
to h2, TLS h1 fallback, redirects as returned responses, trailers, HEAD,
early 413, large response bodies, SSE payloads, zero-byte h2 responses, and
WebSocket upgrade rejection as an ordinary HTTP response. It also covers h1
100-Continue final-response handling, a mid-body server close, h2 large-body
flow-control progress, and server-push rejection through nghttpd.

It does not claim eta-http supports h2c prior knowledge through the public
client API. h2c is covered with curl/nghttp2 against Caddy to prove the real
fixture, and the eta-http gap is recorded in coverage_matrix.md.
