---
id: Eta-u1f
title: "P1: H2 read loop must surface buffer-full as typed Security_error"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:04:44.521Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — h2/multiplexer.ml replaces failwith/assert with typed
  Security_error (44f46a7)
---

# P1: H2 read loop must surface buffer-full as typed Security_error

## description

Bug: packages/eta-http/h2/multiplexer.ml read_client_once (lines 178–188) raises failwith 'read buffer made no parser progress' and assert false on adversarial input that fills the read buffer without producing parser progress. The function already has a Security_error result variant — exceptions on a network-input boundary are the wrong shape and prevent typed error handling.

Location: packages/eta-http/h2/multiplexer.ml read_client_once (Buffer_full branches)

## design

RED test (write first):
1. Build a fake Eio flow that returns frames designed to fill the multiplexer read buffer without yielding any parsable frame (e.g., partial HEADERS frame whose size exceeds buffer capacity, or oversized SETTINGS).
2. Drive read_client_once against it.
3. Assert it returns Security_error _ (typed). Currently raises Failure or Assert_failure.

Fix shape:
- Replace both failwith and assert false with Security_error <variant> returns. Add a new Buffer_exhausted variant to H2.Security or reuse the closest existing one.
- Audit other H2 paths for the same shape (rg failwith / assert false in h2/).

## acceptance criteria

RED test fails on current code and passes after the fix. No failwith or assert false reachable from network input remains in h2/multiplexer.ml. The new Security_error variant is documented.
