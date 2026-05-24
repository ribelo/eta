---
id: Eta-oj1
title: "P0: Validate HTTP header names and values to prevent CRLF injection"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:03:04.689Z
created_by: backlog
updated_at: 2026-05-24T09:59:52.353Z
close_reason: "Closed by remediation. Header constructors validate RFC-token names and CTL-free values; H1 byte/string/flow writers and the H2 client/header validation path reject CR/LF/NUL injection before emitting request bytes. Verified with nix develop -c dune runtest --force."
---

# P0: Validate HTTP header names and values to prevent CRLF injection

## description

Bug: packages/eta-http/core/header.ml accepts any string for name and value. add and of_list are list-cons / identity with no validation. packages/eta-http/h1/write.ml writes name and value verbatim through three paths (write_to_bytes_raw, write to Buffer, write_to_flow); validate_method exists but no header-name or header-value validation exists anywhere. packages/eta-http/h2/writer.ml has no validation either. A header value containing CRLF injects an additional header line; CRLF CRLF injects a request boundary. This is request-smuggling class.

Locations:
- packages/eta-http/core/header.ml (add, of_list)
- packages/eta-http/h1/write.ml (write_to_bytes_raw, write, write_to_flow)
- packages/eta-http/h2/writer.ml

## design

RED test (write first, must fail on current code):
1. Build a request with header value containing CR LF + 'Injected: 1'. Assert the writer returns Error Header_invalid (or its typed equivalent) and does not produce wire bytes containing the injected line.
2. Same with header name containing CR LF + 'Injected'.
3. Variants with bare LF, bare CR, embedded NUL, and obs-fold (LF + space). All rejected.
4. Same property test on the H2 writer path.

Fix shape:
- Add validated name and value types in Eta_http_core.Header. name rejects non-RFC-token characters. value rejects CR, LF, NUL, other CTL.
- Provide constructors that return (t, Error.t) result.
- All H1 and H2 writer paths consume validated headers only.
- Keep an unsafe_of_list constructor for tests / internal trusted paths.

## acceptance criteria

All four RED tests fail on current code and pass after the fix. All H1 and H2 writer paths share one validation boundary; no path emits unvalidated header strings. Public Header API documents the validation contract.
