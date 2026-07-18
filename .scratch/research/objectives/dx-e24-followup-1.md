# Follow-up 1: DX-E24 — contract amended, resume with reduced scope

Your blocker was verified and upheld on both counts — the optional-last
signatures are unwritable in OCaml, and `Resource.auto` fires the
pre-registered hold trigger. Good stop. The contract is now amended after a
two-round adversarial design consultation (orchestrator + independent
reviewer, consensus reached; see below). Everything in `objective.md` still
applies except where this file overrides it.

## What changed and why

1. **Optional erasure.** Fixed by moving optionals before a trailing
   mandatory argument, and by making `retry`/`repeat` data-last.
2. **`retry_or_else` is NOT absorbed.** New evidence: its two-error form
   (`'err1 -> 'err2`) is genuine typed-error expressiveness that
   `map_error` cannot recover, and the two operations already differ in
   cause semantics today (`retry`: bare `Cause.Fail` only;
   `retry_or_else`: `stripped_uncatchable` + `first_typed_failure`).
   Both stay, with data-last labeled shapes.
3. **`Schedule.t` slimming is HELD** (pre-registered trigger). 3 params,
   `tap_input`/`tap_output`, `no_hook` all stay. No `?on_retry`/`?on_repeat`
   observers anywhere. A future experiment (E24b) will decide hook
   ownership — policy vs. driver — across the full public driver protocol
   (`start`, `driver`, `step`, `step_plan`, `step_with_hooks`, `next`,
   `no_hook`). Out of your scope.
4. **`map_par` is function-first** — Stdlib `List.map` and Eta's own
   `Effect.map`, not Base/Core's `~f`-labeled list-first.

## Final contract (exact)

```ocaml
val map_par :
  ?max_concurrent:int -> ('a -> ('b, 'err) t) -> 'a list -> ('b list, 'err) t
  (* absorbs for_each_par + for_each_par_bounded, both deleted.
     Absent max_concurrent = 8 — today's silent `min n 8`, now documented:
     "Runs at most [max_concurrent] child effects concurrently; the default
     is 8. Fewer fibers are started when the input is shorter."
     Invalid_argument on max_concurrent <= 0 at construction time. *)

val retry :
  schedule:('err, 'out, (unit, 'err) t) Schedule.t ->
  while_:('err -> bool) -> ('a, 'err) t -> ('a, 'err) t

val retry_or_else :
  schedule:('err1, 'out, (unit, 'err2) t) Schedule.t ->
  while_:('err1 -> bool) ->
  or_else:('err1 -> 'out option -> ('a, 'err2) t) ->
  ('a, 'err1) t -> ('a, 'err2) t

val repeat :
  schedule:('a, 'out, (unit, 'err) t) Schedule.t ->
  ('a, 'err) t -> ('out, 'err) t
```

## Semantics (byte-identical to current behavior)

- `map_par`: preserve from `for_each_par[_bounded]` — nonpositive explicit
  bound rejected at construction; mapper callbacks NOT evaluated while
  building the blueprint; input-order collection; fail-fast cancellation
  and finalizer behavior; default cap 8, explicit-cap enforcement.
- `retry` / `retry_or_else` / `repeat`: argument-shape change only. All
  cause semantics, schedule stepping, hook execution, and `or_else`'s
  `None`/`Some` rules unchanged.
- The mli must now **explicitly document the cause-semantics difference**
  between `retry` (bare `Cause.Fail` only) and `retry_or_else` (catchable
  composite causes, first typed failure) — phrased as a *current
  limitation/difference*, not as a virtue. A follow-up will decide whether
  `retry` should adopt the composite semantics; do not change the behavior.

## Protocol adjustments to objective.md

- **Journal:** add an `Amendment predictions (sealed)` section as a NEW
  entry before your first code commit — expected census/footgun deltas and
  reviewer misreadings for the reduced scope. Do not edit your original
  sealed predictions; wrong ones stay as data.
- **Census (rescoped):** iterate cluster 5 vals → 4 (`map_par`, `retry`,
  `retry_or_else`, `repeat`), 5 concepts → 4. `Schedule.t` unchanged.
  Footguns: expect −1/+0 ("`for_each` collects results" removed).
- **Parity suite:** input order under interleavings; fail-fast sibling
  cancellation; explicit-cap enforcement; **default cap 8 proven with >8
  inputs**; `Invalid_argument` at construction for `max_concurrent <= 0`;
  `or_else` receives `None` on first-rejection, `Some out` after steps,
  `Some` terminal at exhaustion; tapped schedules still run their taps
  under the new call shape.
- **Erasure probe (the original blocker):** compile evidence that omission
  calls yield `Effect.t` values, not partial applications —
  `let _ = Effect.map_par (fun x -> eff) xs`, `let _ = eff |> Effect.retry
  ~schedule:s ~while_:p`. Commit under `redteam/` or the parity suite.
- **Red-team:** (a) `map_par ~max_concurrent:0` and `~max_concurrent:(-3)`
  must fail loudly at construction, not silently; (b) a call that *looks*
  like it gets unbounded parallelism by omission — document what actually
  happens (cap 8) and whether the mli sentence prevents the misreading.
- **Review packet:** pair (a) `par-old.ml`/`par-new.ml` — bounded-parallel
  fetch over a list of ids, old vs. new; pair (b) `retry-old.ml`/
  `retry-new.ml` — retry-with-fallback, old positional vs. new labeled
  data-last. `MANIFEST.md`, `QUESTIONS.md` (`?max_concurrent`, `~while_`,
  `~or_else`'s argument, result order).
- **Report:** as before, including a section scoring BOTH prediction sets
  (original + amendment) and noting that the original one-pager's
  `retry_or_else` absorption was reversed — record why in one paragraph.

## Gates

Unchanged from objective.md (native three + mainline compile check of
`test/cache_jsoo` and `test/js_jsoo`; `signal_jsoo` failure output must
match master's — record both, do not fix).

## Done means

Same signals: `E24 READY FOR REVIEW` / `E24 BLOCKED: <reason>` /
`E24 STOP: <§4.6 condition>`. Same scope fence as objective.md. This file
stays uncommitted, like objective.md.
