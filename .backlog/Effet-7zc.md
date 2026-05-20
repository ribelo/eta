---
id: Effet-7zc
title: "B1: Package skeleton for effet-otel"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T11:52:27.594Z
created_by: backlog
updated_at: 2026-05-19T13:55:21.294Z
closed_at: 2026-05-19T13:55:21.294Z
close_reason: packages/effet-otel/ skeleton with dune library (public_name
  effet-otel) and dune-project package stanza. Builds clean.
dependencies:
  - issue_id: Effet-7zc
    depends_on_id: Effet-9w1
    type: parent-child
    created_at: 2026-05-19T11:53:15.475Z
    created_by: backlog
  - issue_id: Effet-7zc
    depends_on_id: Effet-ev6
    type: blocks
    created_at: 2026-05-19T11:53:38.862Z
    created_by: backlog
---

# B1: Package skeleton for effet-otel

## description

Create the packages/effet-otel/ directory tree, dune wiring, and opam package declaration. The library compiles green with a placeholder source file. No actual OTel logic yet; that is B2.

## design

packages/effet-otel/dune declares (library (name effet_otel) (public_name effet-otel) (libraries effet opentelemetry)). dune-project gains (package (name effet-otel) (synopsis ...) (depends ocaml dune effet opentelemetry)). One placeholder source file (e.g., packages/effet-otel/effet_otel.ml) so dune emits the library. Pin the opentelemetry-ocaml library version range during this task to avoid surprises later.

## acceptance criteria

dune build succeeds for the new package alongside effet. effet-otel.opam is generated at the repo root with the right depends list. The new library is empty but importable: a dune-build smoke test or a trivial placeholder export proves the artifact is real.
