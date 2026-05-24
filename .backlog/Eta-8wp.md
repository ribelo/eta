---
id: Eta-8wp
title: "P2: Close TCP flow when TLS upgrade fails"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:04:32.819Z
created_by: backlog
updated_at: 2026-05-24T10:33:19.610Z
close_reason: "Closed by remediation. Added a RED counted-flow test for connect_tls peer-identity failure and changed connect_tls to close the original TCP flow before returning typed TLS failures, including setup and client_of_flow exceptions. Verified with nix develop -c dune runtest --force."
---

# P2: Close TCP flow when TLS upgrade fails

## description

Bug: packages/eta-http/transport/connect.ml connect_tls (line ~97) returns Effect.fail on RNG init, peer-identity parse, or Tls_eio.client_of_flow failure without closing the input flow. The flow is ~sw-bound by connect_tcp, so the realized leak is bounded by switch lifetime — but every TLS failure pins the flow until switch end. Defensive cleanup gap; reviewed-and-demoted from P1 to P2 because severity is switch-architecture-dependent.

Location: packages/eta-http/transport/connect.ml connect_tls

## design

RED test (write first):
1. Construct a Tls_eio config that will fail (e.g., authenticator that rejects everything) against a known TLS test server, or build a fake flow whose negotiation cannot complete.
2. Wrap a long-lived Eio.Switch.run; instrument the underlying TCP flow with a wrapper that increments a counter on close.
3. Trigger connect_tls failure. Within the same switch scope (before switch end), assert the close counter is 1.
4. Currently fails — counter is 0 until switch end.

Fix shape:
- On every failure path inside connect_tls, close the input flow before returning Effect.fail. Use Effect.catch or a Fun.protect-equivalent shape; on error path call Eio.Resource.close flow then re-raise the typed error.

## acceptance criteria

RED test fails on current code and passes after the fix. Successful TLS path still owns and uses the flow correctly (regression check).
