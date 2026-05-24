---
id: Eta-r4c
title: "P2: h2 1xx informational responses, GOAWAY retry, stream ID mirroring"
status: closed
priority: 2
issue_type: bug
created_at: 2026-05-24T12:52:41.312Z
created_by: backlog
updated_at: 2026-05-24T16:26:57Z
closed_at: 2026-05-24T16:26:57Z
close_reason: "Fixed: h2 reader filters interim 1xx HEADERS before ocaml-h2,
  GOAWAY v1 posture is documented as drop-and-disconnect, and stream ID
  assumptions are asserted."
dependencies:
  - issue_id: Eta-r4c
    depends_on_id: Eta-0xe
    type: parent-child
    created_at: 2026-05-24T12:52:47.872Z
    created_by: backlog
---

# P2: h2 1xx informational responses, GOAWAY retry, stream ID mirroring

## description

Three h2 correctness issues:

1. Informational 1xx responses: h2_response_has_body (client/client.ml:195-198) excludes 1xx, and the response handler returns a no-body response when has_body is false. If ocaml-h2 surfaces 100 Continue or 103 Early Hints through the same handler, eta-http returns that as the final response. Fix: explicitly filter/continue 1xx responses until final.

2. GOAWAY retry: probes accept drop-and-disconnect conservative posture. Requests on streams > last_stream_id are not selectively retried. Document that this is acceptable v1 behavior but a missing feature relative to robust h2 clients.

3. Stream IDs mirrored: Stream_state.open_stream (h2/multiplexer.ml:24-83) assigns its own stream ID before H2.Client_connection.request. If ocaml-h2 changes allocation or emits pushed streams, eta-http's state diverges. Bind to actual h2 request handle if library exposes one.

Location: packages/eta-http/client/client.ml:195-198, 307-323; packages/eta-http/h2/multiplexer.ml:24-83

## design

1. Ignore or expose 1xx responses separately, continue reading until final non-1xx. 2. Document GOAWAY posture; add retry classification when h2 exposes last-stream-id. 3. Add strict assertions around stream ID assumptions; release state on every request-call failure path.

## acceptance criteria

1xx responses filtered/continued. GOAWAY posture documented. Stream ID assumptions asserted.

## 2026-05-24 closure

Closed for the v1 contract.

- eta-http filters h2 interim 1xx response HEADERS, except 101, before bytes
  reach ocaml-h2. The filter decodes server HPACK blocks, drops interim blocks,
  re-encodes final response/trailer blocks, and preserves decoder state across
  dynamic-table references.
- packages/eta-http/test/test_eta_http_h2_connection.ml has a raw h2 fixture
  that sends HEADERS(103) -> HEADERS(200) -> DATA(END_STREAM), with a reused
  HPACK dynamic-table entry across interim and final blocks.
- GOAWAY remains documented as conservative drop-and-disconnect in
  packages/eta-http/README.md. Selective retry above last_stream_id is not a v1
  claim because the pinned substrate does not expose received last_stream_id.
- Stream ID assumptions are explicit through
  Eta_http.H2.Stream_state.is_client_stream_id and an invariant check in
  open_stream; eta-http tests cover positive-odd client stream IDs.
- Verification: nix develop -c dune runtest packages/eta-http --force.
