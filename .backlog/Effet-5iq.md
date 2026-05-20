---
id: Effet-5iq
title: ppx_effet — [%effet.fn body] sugar
status: closed
priority: 4
issue_type: task
created_at: 2026-05-19T14:25:46.354Z
created_by: backlog
updated_at: 2026-05-19T15:17:01.614Z
closed_at: 2026-05-19T15:17:01.614Z
close_reason: Added separate ppx_effet package using ppxlib with [%effet.fn
  body] expansion to Effet.Effect.fn __POS__ __FUNCTION__ body, test proving
  span name/loc capture, README usage docs, flake/dune package wiring, and nix
  develop -c dune runtest --force passes.
---

# ppx_effet — [%effet.fn body] sugar

## description

V-O5 documents Effect.fn __POS__ __FUNCTION__ body as the canonical idiom for span auto-naming. V-O9 lists 'PPX [%effet.fn body]' as deferred DX. Every span call site repeats __POS__ __FUNCTION__ — boilerplate that a small ppx eliminates. Trade-off: ppx adds build complexity (ppxlib dependency, separate package) for syntactic compression. Worth shipping once core API is stable so users don't have to rewrite call sites.

## design

Separate package packages/ppx_effet/ using ppxlib. Single extension point: [%effet.fn body] expands to Effect.fn __POS__ __FUNCTION__ body. Optionally [%effet.named 'name' body] expands to Effect.fn __POS__ 'name' body for cases where the user wants to override the OCaml binding name. dune-project gains (package (name ppx_effet) (synopsis 'PPX rewriter for effet span sugar')). Effet itself does not depend on ppx_effet; it is opt-in. README.md gains a section showing both the manual idiom and the ppx version side-by-side. The ppx is intentionally minimal: no inference of attribute keys, no automatic instrumentation — just position+function-name capture.

## acceptance criteria

packages/ppx_effet/ builds as a separate opam package depending on ppxlib. Using [%effet.fn (Effect.pure 1)] in a test produces a span with the same name and loc attribute as Effect.fn __POS__ __FUNCTION__ (Effect.pure 1) — verified by an in-memory tracer dump comparison. README.md or a docs/ppx.md documents the extension and shows installation. ppx_effet test runs under nix develop -c dune runtest --force. Existing effet tests are unaffected (the core does not depend on the ppx).
