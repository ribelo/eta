---
id: Eta-0xe
title: "eta-http: Client/H1/H2/Security/Transport findings"
status: open
priority: 1
issue_type: epic
created_at: 2026-05-24T12:49:44.643Z
created_by: backlog
updated_at: 2026-05-24T16:00:37Z
dependencies:
  - issue_id: Eta-0xe
    depends_on_id: Eta-cu7
    type: parent-child
    created_at: 2026-05-24T12:49:51.100Z
    created_by: backlog
---

# eta-http: Client/H1/H2/Security/Transport findings

## description

P0/P1/P2/P3 findings from the 2026-05-24 code review affecting packages/eta-http/ — h2 write-before-read serialization, stream admission leak, receiver buffer undersized, h1 release callback bypass, CONTINUATION 0-length flood, origin pool unbounded growth, security rate-limit naming, delegation boundary undocumented, no-body pool checkout held, request-body discard on write failure, informational 1xx response handling, GOAWAY retry granularity, header value HTAB rejection, TLS revocation gap, h2 stream ID mirroring, response body ownership, stale README, empty frame skeleton.

## acceptance criteria

All P0 and P1 child tasks closed with fixes + tests. P2 tasks triaged. P3 tasks acknowledged.

## 2026-05-24 status

P0/P1 eta-http child tasks are closed, including Eta-p21. The epic stays open:
P2/P3 triage remains, and Eta-r4c is still open because robust h2
informational-response support is blocked by the pinned ocaml-h2 behavior
described in that task.
