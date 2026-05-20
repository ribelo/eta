---
id: Effet-6f8
title: "Research: Layer alternatives V-R2 reopened (manual-output merge + GADT
  presence-set)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:38:17.098Z
created_by: backlog
updated_at: 2026-05-19T23:33:17.255Z
closed_at: 2026-05-19T23:33:17.255Z
close_reason: "Completed. Layer research lab in scratch/layer_research/ tested
  merge_explicit and GADT presence-set candidates against no-Layer baseline.
  Decision diary V-RLv1–V-RLv5 recorded in journal.md lines 4988–5250.
  Recommendation (a): V-R2 holds — no Layer module. merge_explicit is
  technically viable but not materially better than ordinary OCaml; GADT
  presence-set rejected."
dependencies:
  - issue_id: Effet-6f8
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:12.709Z
    created_by: backlog
---

# Research: Layer alternatives V-R2 reopened (manual-output merge + GADT presence-set)

## description

Review 1 finding #2. V-R2 rejected Layer.t because OCaml has no type-level intersection of object rows for inferred Layer.merge. The journal cites three workarounds — phantom lists, Hmap, restricted merge — and rejects each, but the candidate set is incomplete:

Missing candidate 1: Layer.merge_explicit ~combine.
val merge :
  combine:('a -> 'b -> 'out) ->
  ('rin, 'err, 'a) t ->
  ('rin, 'err, 'b) t ->
  ('rin, 'err, 'out) t
This concedes that OCaml cannot infer object-row intersection but asks whether explicit ~combine is acceptable at the call site.

Missing candidate 2: GADT presence-set with hidden witnesses.
type _ cap = Clock : Clock.t cap | Db : Db.t cap
type (_, _) has = Here : (_ * _, _) has | There : (_, _) has -> (_, _) has
type ('need, 'provide, 'err) layer
The journal calls this 'unmaintainable' in prose without testing whether smart constructors can hide the witnesses.

If either candidate produces an acceptable Layer surface, V-R2 should be revisited. If both fail, the rejection becomes evidence-backed instead of asserted.

## design

scratch/layer_research/ with both candidates as compiling modules.

Fixture: two scoped services that depend on a shared Clock service. Db_layer needs Clock; Http_layer needs Clock and Log; App = merge(Db_layer, Http_layer). Then Boot provides Clock, Log; observe whether the type system tracks unmet requirements and produces useful errors when Clock or Log is missing.

Negative tests: forgetting to provide Clock at boot must produce a compile error pointing at the missing service. Method-name collisions on shared service types must produce useful errors.

Compare against the current 'no Layer' answer (object row + scoped factories + bind). If neither candidate beats the existing answer materially, V-R2 holds.

## acceptance criteria

scratch/layer_research/ contains Layer.merge_explicit and GADT-presence-set candidates as compiling modules with the shared-Clock fixture and negative tests. journal.md gains a V-RLv1..V-RLvN decision diary recording per-candidate pass/fail/cost. Recommendation is one of: (a) V-R2 holds, no Layer module; (b) ship Layer.merge_explicit as a small primitive — capture as implementation task; (c) ship GADT-presence-set Layer — capture as implementation task; (d) more research needed. 3h time budget.
