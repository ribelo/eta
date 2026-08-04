# eta_crux design map

## Destination

eta_crux V1 design locked and implementation-ready: every remaining decision closed so
implementation can begin with nothing left to decide. V1 uses **plain mutable state** as
its state representation, factored so an `eta_signal` graph backend can be added later
without redesign. Planning only — implementation is not a deliverable of this map, though
a prototype that unblocks a decision is in scope as a ticket.

## Notes

This map is inactive. The
[Eta Crux first-principles design map](../eta-crux-first-principles/map.md)
replaced it as the canonical route. No open child ticket in this map is
takeable.

Domain: an optional OCaml package on the Eta effect runtime. Applications own state; Eta
owns effect description and interpretation. Requirements live in
`docs/requirements/eta-crux/` and are the output of the decisions made here.

Working agreements:

- Skills: `$batch-grill-me` and `$domain-modeling` for grilling tickets, `$prototype` for
  prototype tickets, `$research` for research tickets, `$ears` and `$to-requirements` to
  reflect a resolved decision into the requirement notes.
- Requirement notes carry no rationale, no change narrative and no lifecycle status. Every
  requirement bullet ends in a native block ID (`^id`). Rationale for a hard-to-reverse
  choice belongs in an ADR under `docs/adrs/`.
- Verify claims about Bonsai, Incremental, Iced, Crux, Foldkit, GPUI and Syzygy against the
  local checkouts in source rather than from memory: `.reference/crux`,
  `.reference/foldkit`, `.reference/syzygy`, and
  `/home/ribelo/projects/github/{bonsai,incremental,iced,zed}`.
- Several reviewers raise gaps against Elm and Crux. Some tickets here reopen a decision
  already recorded in the notes; a ticket that reverses a recorded decision must say so in
  its answer and update every affected note.
- Do not spawn subagents to write in this worktree. The sandbox mounts everything outside
  the master checkout read-only, so a child's writes land in the wrong tree or fail.
- Work happens on branch `docs/eta-crux-requirements` in the `../Eta-eta-crux` worktree.
  Run `nema sync` from the master checkout after merging, never from here.

## Decisions so far

<!-- one line per closed ticket: enough to judge relevance, then follow the link -->

- [Vocabulary: Elm names and the Task framing](issues/03-vocabulary-elm-names.md) — Eta Crux keeps precise native terms, uses lists for composition, and documents Elm analogues without compatibility.

## Not yet specified

- **The public API surface.** Roughly eleven questions across the notes — the application
  handle and driver operations, cell and computation-value types, fragment constructors and
  address exposure, scheduled-command constructors and the slot API, subscription spec
  declaration, the admission-failure type, crash-report fields, the capability-message
  sender's type and lifetime, and observed-cell selection for exhaustive assertions. All of
  them take different answers depending on
  [State representation seam and plain-state V1](issues/01-state-representation-seam.md)
  and [One public API across both state backends](issues/02-one-api-across-backends.md),
  so this graduates once those land — possibly into several tickets.
- **Slint adapter specifics.** Whether the first binding is hand-written or generated from
  `.slint`, which package owns the generic transport glue, and the value-conversion API
  from typed fragments to host properties and row models. Needs a scope call first:
  the adapter *contract* is in scope, but the concrete `eta_crux_sliml` binding may be its
  own effort.
- **Driver and tick details beyond ordering.** Whether `max_batch` is global or per
  instance, whether a tick producing only suppressed output changes still notifies, whether
  a same-domain drain operation exists for immediate-mode hosts, and whether more than one
  owner domain is ever allowed.
- **Graph-backend semantics deferred out of V1.** For input-dependent cells, whether the
  backend settles before processing an action — the question that Bonsai answers with a
  stabilization tracker. It does not arise under plain state and returns with the graph
  backend.
- **Composition ergonomics.** Threading a parent's scheduled-command constructor through nested
  children, and whether a dedicated upward-output channel exists alongside it.

## Out of scope

- [State representation seam and plain-state V1](issues/01-state-representation-seam.md)
  closed without a decision because the canonical map rejected its plain-state
  premise.

- The `eta_signal` redesign and the `eta_signal_map` implementation. Only the contract
  eta_crux depends on is in scope, in
  [eta_signal_map and minimal eta_signal hook contract](issues/16-eta-signal-map-contract.md);
  the packages themselves are a separate effort.
- Concrete wire schemas for cross-process transport. Which payloads require serialization
  is a decision here; designing the encodings is not.
- eta_crux implementation as a deliverable, including a shippable walking skeleton.
