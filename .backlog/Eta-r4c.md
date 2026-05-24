---
id: Eta-r4c
title: "P2: h2 1xx informational responses, GOAWAY retry, stream ID mirroring"
status: open
priority: 2
issue_type: bug
created_at: 2026-05-24T12:52:41.312Z
created_by: backlog
updated_at: 2026-05-24T16:00:37Z
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

## 2026-05-24 triage

Partial progress landed, but this task remains open.

- eta-http now classifies 1xx h2 statuses as interim if the substrate surfaces
  them, and the h2 response handler ignores those statuses rather than
  returning them as final responses.
- The pinned ocaml-h2 line still treats the first response HEADERS as the
  active response. A raw 103 followed by final 200 is rejected as malformed
  trailers (HEADERS frames containing trailers must set the END_STREAM flag),
  so robust h2 informational-response support needs a substrate fix or deeper
  adapter work.
- GOAWAY remains documented as conservative drop-and-disconnect in
  packages/eta-http/README.md; selective retry above last_stream_id remains
  deferred because the pinned substrate does not expose last_stream_id.
- Stream ID assumptions are now explicit through
  Eta_http.H2.Stream_state.is_client_stream_id and an invariant check in
  open_stream; eta-http tests cover the positive-odd client stream IDs.
