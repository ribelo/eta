# H1 TLS handshake latency — ideas backlog (ordered by expected impact)

Diagnosis: the p99 outlier is TLS handshake cost (~1.4ms RSA-2048 sign per full
handshake; serialized across c=16 on one core). Reduce per-handshake cost
and/or parallelize handshakes.

## 1. TLS session resumption / session tickets (potential big win)
A resumed handshake (TLS 1.3 PSK / 1.2 session ticket) skips the RSA signature
— the dominant cost. Check whether ocaml-tls/Tls_eio server context advertises
& accepts tickets, and whether the server already supports resumption. Verify
what oha does on a new TCP connection: does it present a cached ticket (1-RTT
resumption) or always full handshake? If oha never resumes, this won't move the
benchmark even if correct — measure before investing.

## 2. Remove the per-handshake with_timeout fork (server.ml)
`run_https_connection` wraps `Tls_eio.server_of_flow_with_context` in
`time.with_timeout config.tls_handshake_timeout` — a sleeper fiber + Zzz timer
node per handshake. Same anti-pattern removed from the H1 plain path (read/
handler/write) for −45% p99. Replace with a watchdog/deadline that doesn't fork
per handshake, or arm only if the handshake doesn't complete synchronously.

## 3. Parallelize CPU-bound handshakes across domains
The single-domain server serializes 16 concurrent RSA signs. The handshake is
CPU-bound and independent per connection. A handshake-offload domain pool (or
`domain_policy`/`additional_domains` on the HTTPS listener) would let multiple
cores chew handshakes in parallel — directly attacks the c=16 serialization
that turns a 1.4ms sign into a 2.66ms p50 / multi-ms tail. Mind Eta's
mode/portability fences and that request handling stays correct.

## 4. TLS 1.3-only fast path / group ordering
Ensure TLS 1.3 + X25519 ECDHE is the negotiated path (fastest key exchange).
Check `policy_version`/cipher ordering in config.ml; avoid any FFDHE fallback.
Probably small (we're already ECDHE) but verify no slow group is reachable.

## 5. mirage-crypto RSA backend
Confirm the accelerated bignum path is linked (the RSA-2048 sign dominates).
If pure-OCaml fallback is in use, that explains ~1.4ms; the fix may be a
build/dependency adjustment rather than Eta code.

## 6. Handshake-flight write coalescing (tls_eio.ml)
Fewer/larger socket writes for the multi-flight handshake. TCP_NODELAY is
already on, so this is about syscall count, not Nagle — likely small.

## Notes / dead ends
- TCP_NODELAY already set on accepted flows (server.ml) — not the cause.
- Tls_eio server context built once per listener — not per-connection rebuild.
- Steady-state H1 TLS latency is already fine (~0.2ms p50) — do NOT optimize the
  request path; the entire win is in the handshake.
