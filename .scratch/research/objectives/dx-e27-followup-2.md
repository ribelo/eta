# Follow-up 2: DX-E27 — deferral is partial; redesign to the closure API

The review found a HIGH: `Format.kdprintf` does NOT defer built-in
conversions. `CamlinternalFormat.make_printf` converts `%d`/`%f`/`%S`/
padding/precision EAGERLY at construction (reviewer's probe:
`"%1000000d"` allocated ~1 MB before the printer was invoked); only
`%a`/`%t` printers and final output assembly are deferred. And the
evidence couldn't see it: the benchmark reused ONE prebuilt blueprint
100k times (construction amortized away), and every invocation test
used `%a` — the one conversion that IS lazy.

The core claim as written ("formatting runs once only after runtime
level admission") is false for built-in conversions. Two shapes were
possible; the orchestrator's decision:

## Decision: closure API (thunk), not a narrowed format4 contract

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  (Format.formatter -> unit) ->
  (unit, 'err) t
```

Use-site:

```ocaml
Effect.logf (fun fmt -> Format.fprintf fmt "db.find %d" id)
Effect.logf pp_db_find          (* composes with the E7 pp culture *)
```

Why (record this reasoning in the journal):

1. **Honest, complete deferral.** The closure runs only after level
   admission — conversions AND arguments inside it are deferred
   (`Format.fprintf fmt "len %d" (Queue.length q)` defers the length
   call too). The format4 encoding cannot offer this, ever
   (`make_printf` is eager by design).
2. **T2: the wrong thing looks wrong.** The format4 version INVITES the
   misreading "all formatting is deferred" — it fooled the
   orchestrator (the sealed predictions claim it) and the first
   evidence suite. A semantic that fools its authors will fool users.
   The closure's deferral is syntactically visible.
3. **T8: doc budget.** The narrowed format4 contract needs three
   caveat sentences ("%a/%t lazy; builtins eager; output+record gated").
   The closure needs one: "the formatter runs once, only after runtime
   level admission." A semantic that fits the budget wins.

The alternative (format4 with the narrowed three-sentence contract) is
rejected but recorded: write its exact proposed mli text into the
journal's alternatives section with the rejection reason.

## What changes

1. `logf`'s signature and implementation: `(Format.formatter -> unit)`
   invoked inside the level gate; disabled → closure never invoked.
2. The mli: one-sentence deferral contract + the eager-args sentence is
   REPLACED by the stronger truth (args inside the closure are
   deferred; args outside are eager as usual).
3. **The measurement must construct per emission** (no blueprint
   reuse): disabled construction+filter vs enabled construction+emit,
   minor-words each — and the `%1000000d` adversarial case (disabled
   must NOT allocate it).
4. Invocation tests must cover `%d` (builtin), `%a` (user printer),
   and `%t`, each with invocation counters: disabled → never invoked;
   enabled → exactly once.
5. The retention finding (MEDIUM): the closure retains its captured
   args for the blueprint's lifetime — disclose in the mli (one clause;
   that's the honest cost; a permanently-filtered long-lived blueprint
   still retains less than a built record chain — state it without
   overclaiming either way).

## LOW: LAWS.md totals

`.scratch/research/dx/e22/review/LAWS.md`: external Effect rows 93 →
97, overall 110 → 114, covered 213 → 217. Reconcile the headline.

## Records and gates

Journal: append-only — the kdprintf eager-conversion evidence (credit
the reviewer's probe), the sealed-prediction correction (the
orchestrator's sealed deferral claim was wrong — record it), the shape
decision with the rejected alternative's exact text. Report: updated
with the corrected measurement. Gates: full set (`_build-mainline` for
mainline).

## Done means

`E27 READY FOR REVIEW` / `E27 BLOCKED: <reason>` / `E27 STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
