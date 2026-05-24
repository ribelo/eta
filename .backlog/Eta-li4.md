---
id: Eta-li4
title: "P2: H1 write_to_flow must return typed errors instead of raising"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:07:09.544Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — part of code review remediation commit (44f46a7)
---

# P2: H1 write_to_flow must return typed errors instead of raising

## description

Bug: packages/eta-http/h1/write.ml write_to_flow (line 202) returns (unit, Error.t) result but only fills Error for an invalid method. All Eio.Flow.copy_string calls can raise (broken pipe, connection reset, end of file). The signature implies typed errors; the function still raises through Eio. Same shape applies to write_string / write_bytes / write_header_line helpers it calls.

Location: packages/eta-http/h1/write.ml write_to_flow and the write_string/write_bytes/write_header_line helpers

## design

RED test (write first):
1. Construct a fake Eio flow whose copy_string raises End_of_file (or Eio.Io _) on the first write.
2. Call Eta_http_h1.Write.write_to_flow against it with a valid request.
3. Assert the function returns Error _ (typed). Currently the exception escapes the function.

Fix shape:
- Wrap each write_* helper in a translation that catches Eio flow exceptions and returns Error.Io_error / Connection_closed / equivalent.
- Or update the .mli to document explicitly that the function can raise Eio flow exceptions. eta-http otherwise prefers typed errors — go with the typed-error path.

## acceptance criteria

RED test fails on current code and passes after the fix. Successful flow path still returns Ok () (regression). The .mli documents the chosen contract clearly.
