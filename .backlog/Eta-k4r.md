---
id: Eta-k4r
title: "H-P1: eta-http v1 has explicit product semantics for redirects,
  trailers, HEAD, early responses; cookies are out-of-scope"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-22T15:25:54.523Z
created_by: backlog
updated_at: 2026-05-24T15:19:28Z
closed_at: 2026-05-24T15:19:28Z
close_reason: Documented — h_p1_product_semantics records redirect, cookie,
  trailer, HEAD, early-response, and pipelining defaults as v1 contract.
dependencies:
  - issue_id: Eta-k4r
    depends_on_id: Eta-adr
    type: parent-child
    created_at: 2026-05-22T19:03:57.775Z
    created_by: backlog
---

# H-P1: eta-http v1 has explicit product semantics for redirects, trailers, HEAD, early responses; cookies are out-of-scope

## description

HYPOTHESIS (per Review #2). eta-http v1 either supports or explicitly rejects each behavior with safe documented defaults: (a) HTTP redirects (301/302/303/307/308 — different method-rewriting semantics), (b) cookie jars (out-of-scope, header-explicit), (c) trailers (h1 chunked + Trailer header; h2 HEADERS/CONTINUATION with END_STREAM), (d) HEAD requests (must not block on body even if Content-Length is set), (e) early responses (server returns 4xx while client still uploading — drain or close cleanly), (f) HTTP/1.1 pipelining (out-of-scope, document why). Decisions documented as a product-semantics ADR set. Defaults err toward explicit over magical (no auto-redirect, no auto-cookie). WHY IT MATTERS. These are API decisions users will depend on. Redirects have ambiguous historical method-rewriting (301/302 sometimes rewrite POST to GET; 307/308 preserve method). Cookies as ambient jar is foot-gun-prone for an HTTP transport library; header-explicit means callers know exactly what's being sent. BLAST RADIUS. Medium-large. Failure means eta-http ships with magical behavior users don't expect, OR with hard-coded denial of features they need. FAST FALSIFIER. scratch/eta_http_research/h_p1_product_semantics/. Decision matrix per behavior with: (default behavior, opt-in/opt-out config, RFC reference, justification). Build fixtures testing the agreed defaults: 301/302/303/307/308 from local fixture, cross-host redirect carrying Authorization (must NOT auto-forward by default), Set-Cookie response (NOT stored by default), chunked + h2 trailers (delivered, not auto-stripped), HEAD with misleading Content-Length (does not block on body), early 413 mid-upload (drains/closes cleanly). Verify each fixture produces the documented decision.

## design

DISPROOF SIGNATURES. A decision is impossible to implement without breaking another (e.g., redirect handling and retry policy collide). Or trailer delivery requires a body API change that breaks H-D2a. Or HEAD response handling needs special-casing throughout the codebase. POSITIVE EVIDENCE NEEDED. All six fixtures produce documented behavior. Defaults are conservative (no surprises). Each decision has a one-paragraph justification with RFC reference. ARTIFACTS. scratch/eta_http_research/h_p1_product_semantics/{decisions.md, redirects_adr.md, cookies_adr.md, trailers_adr.md, head_adr.md, early_response_adr.md, pipelining_adr.md, fixtures/, dune, README.md, results.md}. Journal entry V-Http-P1. CONNECTS TO H-D2a (request API surfaces these decisions) and H-D-Errors (early response surfaces as structured error).

## acceptance criteria

scratch/eta_http_research/h_p1_product_semantics/ exists with all six ADRs and fixture matrix. results.md confirms documented behavior. Verdict explicit. Journal entry V-Http-P1 added with the product-semantics ADR set.
