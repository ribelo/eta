# Follow-up 2: DX-E41 — final `with_auto` shape: no optionals, `on_refresh_error` split

Your BLOCKED was verified and upheld: `?on_error` is unerasable at `let@`
sites, so neither follow-up-1 endpoint works. The mechanism is now pinned
(orchestrator probe + your tests): erasure fires on positional application
after the optional, on full application, or on a fully-pinned expected type
— and ppx_let does not propagate the expected type early enough. **No
optional argument can appear in this signature.** The contract is amended
as follows (oracle consultation, consensus).

## Final contract

```ocaml
val with_auto :
  load:('a, 'err) Effect.t -> schedule:(unit, 'out) Schedule.t ->
  (('a, 'err) t -> ('b, 'err) Effect.t) -> ('b, 'err) Effect.t

val with_auto_on_refresh_error :
  on_refresh_error:('err -> unit) ->
  load:('a, 'err) Effect.t -> schedule:(unit, 'out) Schedule.t ->
  (('a, 'err) t -> ('b, 'err) Effect.t) -> ('b, 'err) Effect.t
```

- **Zero optional arguments.** `with_auto` is the canonical form;
  `with_auto_on_refresh_error` is the rare form — fully labeled, required
  `~on_refresh_error`. Both delegate to one private helper taking an
  explicit option.
- **The name is `on_refresh_error`, not `on_error`.** The callback observes
  only *typed refresh* failures — the bare name is channel-blind (seed
  failure? body failure? defect?). mli states exactly what fires it:
  typed refresh failures only; seed failure fails the acquisition and never
  calls it; a raising callback is recorded as `Cause.Die _` after the typed
  failure and the loop continues (the R173 contract, moved to the new name).
- **`?random` is gone** (zero users). Settle the open investigation:
  does the refresh loop honor E19's `with_random` scoped override? Check
  what `Schedule.start` uses when no `~random` is passed and whether the
  scoped override resolution (`runtime_core.ml:196-197`) reaches the loop's
  driver start. Verdict in the journal: reached (document one sentence in
  the mli: deterministic jitter via `Effect.with_random`) or unreachable
  (name the missing seam — E43 material; no workaround).

## Required

1. Both functions implemented via the private helper; all call sites
   migrated: the four `~on_error:observe` sites →
   `with_auto_on_refresh_error`; every forced `?random:None` removed.
2. **Erasure regression tests** (the point of the whole amendment):
   `let@ h = Refreshable.with_auto ~load ~schedule in …` and
   `let@ h = Refreshable.with_auto_on_refresh_error ~on_refresh_error
   ~load ~schedule in …` — both compile with zero optional mentions;
   direct-call forms unchanged. Promote into the parity suites.
3. Law registry: rows referencing `on_error` (R173 and any others) updated
   to the new name and split; coverage pointers exact.
4. Census note: `eta_cache` is now +6 vals vs. the sealed +5 (amendment
   recorded in the orchestrator log; just confirm the actuals).
5. Docs: `docs/api-dx.md` and the example teach the canonical form first;
   the alerting form appears as the explicit rare spelling.
6. Journal: record the empirically established erasure rule precisely
   (what fired, what didn't, compiler messages) — this is the programme's
   second erasure lesson and future experiments will cite it. Plus the
   `with_random` reach verdict.
7. Report: append a `Follow-ups outcome` section (followup-1 superseded
   by followup-2; do not rewrite the original body).
8. Full four-gate quartet.

## Done means

`E41 READY FOR REVIEW` (or `E41 BLOCKED: <reason>`). Same scope fence.
This file stays uncommitted.
