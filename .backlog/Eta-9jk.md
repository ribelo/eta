---
id: Eta-9jk
title: "P1: Cap close-delimited and read_all body sizes"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:04:55.678Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — all body shapes capped at configurable default, uniform
  across close-delimited/chunked/fixed (44f46a7)
---

# P1: Cap close-delimited and read_all body sizes

## description

Bug: packages/eta-http/h1/client.ml enforces max_response_body_bytes = 1_048_576 only when Content-Length is present (line ~382). close_delimited_body (line ~351) has no byte cap. body/chunked.ml defaults to 256 * 1024 * 1024. body/stream.ml read_all accumulates without cap. Three different defenses (1 MiB / 256 MiB / unbounded) across three body shapes; close-delimited is the gap.

Locations:
- packages/eta-http/h1/client.ml close_delimited_body
- packages/eta-http/body/stream.ml read_all

## design

RED test (write first):
1. Build a fake source that yields close-delimited bytes up to e.g. 50 MiB.
2. Issue a request whose response uses close-delimited framing (no Content-Length, not chunked).
3. Assert the body read returns Body_too_large after the configured cap. Currently runs to memory exhaustion or never terminates.
4. Second test: Body.Stream.read_all against a body that yields more than the cap returns the typed error rather than allocating a giant buffer.

Fix shape:
- Make body-byte cap a single configurable value at the client layer; apply it uniformly to fixed, chunked, and close-delimited bodies.
- Enforce the cap inside Body.Stream.read_all (return typed error, do not allocate beyond cap).
- Pick a default that aligns the three shapes; lean toward the smaller cap unless there is a documented reason otherwise.

## acceptance criteria

Both RED tests fail on current code and pass after the fix. All three body shapes share the same default cap and the same configuration knob. Cap is documented in client.mli.
