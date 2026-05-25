---
id: Eta-adr
title: "Phase H-Q: Quality, conformance, security for eta-http"
status: open
priority: 2
issue_type: epic
created_at: 2026-05-22T14:41:20.161Z
created_by: backlog
updated_at: 2026-05-22T14:41:40.596Z
dependencies:
  - issue_id: Eta-adr
    depends_on_id: Eta-7ov
    type: blocks
    created_at: 2026-05-22T14:41:40.496Z
    created_by: backlog
  - issue_id: Eta-adr
    depends_on_id: Eta-ck1
    type: parent-child
    created_at: 2026-05-22T14:41:40.596Z
    created_by: backlog
---

# Phase H-Q: Quality, conformance, security for eta-http

## description

Probes the claim that eta-http v1 ships at production quality. Interop-correct against curl/nghttp2/real cloud servers. Conformance-tested via property tests on the protocol layer. Malicious-server-resilient against published HTTP/2 attack vectors. Four hypotheses. H-Q1 conformance via interop plus property tests. H-Q2 Rapid Reset (CVE-2023-44487) mitigation. H-Q3 HPACK bomb plus CONTINUATION flood mitigation. H-Q4 bidirectional curl interop. Failures here delay v1 until mitigations land; they do not pivot the project. Blocked by Phase H-D's H-D1.

## acceptance criteria

All four hypothesis tasks closed with explicit verdict. Phase verdict published as V-Http-Phase-Q with the security mitigation set, the conformance test matrix, and the interop result tally. ADRs filed for any defensive default that becomes part of the eta-http public API contract (max concurrent streams, max header block size, dynamic table size, etc.).
