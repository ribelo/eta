# DX-E24 Journal — Iteration mirrors `List`

Branch: `research/dx-e24-iteration-mirrors-list`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24`
Phase: A (idiom pass)

## Predictions (sealed)

Sealed before any code or signature edits. Wrong predictions stay as data; this
section will never be edited after the predictions commit.

### Teach-back expected answers

1. **What does `?max_concurrent` do?**
   When present, it limits the number of mapper effects running concurrently;
   values at or below zero raise `Invalid_argument` immediately. When absent,
   `map_par` has the old `for_each_par` behavior: no caller-selected bound (the
   runtime implementation may still use its existing worker strategy). The
   option does not change result ordering or failure semantics.

2. **What does `~while_` do?**
   It decides whether a typed failure is eligible for a schedule step and retry.
   A false result rejects that failure before another schedule step. If this is
   the first failure, `?or_else` therefore receives `None`; after prior accepted
   steps it receives the latest schedule output as `Some out`.

3. **What order does `map_par` return?**
   Input order, regardless of child start or completion order. It maps like
   `List.map` in collection shape, not completion order.

4. **What happens to siblings when one mapper fails?**
   Fail-fast cancellation is unchanged: the observed failure stops the parallel
   group, running siblings are cancelled, and their scoped cleanup completes
   before the parent result settles.

5. **What do retry/repeat observers control?**
   They observe loop values and schedule outputs but cannot change schedule or
   predicate control flow. Their successful value is ignored. A typed observer
   failure replaces the loop result through ordinary typed sequencing; defects
   and interruption likewise propagate normally.

### Expected census / footgun deltas

Independent pre-census of the fixed iterate cluster contract:

| Metric | Before | Predicted after | Delta |
|---|---:|---:|---:|
| Public vals | 5 | 3 | −2 |
| User-facing concepts | 5 | 2 | −3 |
| `Schedule.t` parameters | 3 | 2 | −1 |
| Schedule tap vals | 2 | 0 | −2 |

Before vals: `for_each_par`, `for_each_par_bounded`, `retry`,
`retry_or_else`, and `repeat`. After vals: `map_par`, `retry`, and `repeat`.
The orchestrator's concept count treats optional bounded/unbounded mapping as
one iteration concept and retry/repeat policy-driving as the second, hence
5 → 2 even though three vals remain.

**Footgun delta:** expect **−2 / +0**.

- Removed trap 1: choosing between two parallel-map names and remembering that
  the bound label was `~max` rather than a single optional `?max_concurrent`.
- Removed trap 2: choosing `retry` versus `retry_or_else` and remembering their
  positional schedule/predicate/effect order rather than one labeled contract.
- No new trap predicted: `map_par` mirrors `List.map ~f`, labels make schedule
  and predicate roles explicit, and the mli will state observer failure and
  fallback-output semantics.

### Two likeliest reviewer misreadings

1. **“No `?max_concurrent` means sequential or an undocumented public cap.”**
   The intended reading is old `for_each_par`: concurrent mapping without a
   caller-selected bound. The optional argument is only the public bound knob;
   tests must separately prove order, fail-fast cancellation, and the supplied
   bound.

2. **“`?on_retry` can veto a retry, or observer failure is swallowed.”**
   The observer returns an effect only to observe in Eta's typed/runtime context;
   it does not return a control decision. Successful observation cannot stop a
   loop. Failed observation fails the typed channel normally and prevents later
   loop work.

### Migration / parity prediction

- Expect the compiler-guided migration to remove every public occurrence of
  `for_each_par`, `for_each_par_bounded`, `retry_or_else`, `Schedule.tap_input`,
  and `Schedule.tap_output`, including docs and the known jsoo files.
- Expect all existing schedule behavior to survive after deleting hook-bearing
  constructors, suspended hook steps, and the third type parameter.
- Expect parity tests to show input order under forced interleavings, sibling
  cancellation, peak bound enforcement, loud invalid bounds, all three fallback
  output cases (`None`, prior `Some`, terminal `Some`), observer failure, and
  observer event order.
- Predict the known `test/signal_jsoo` failure remains byte-for-byte equivalent
  in its substantive compiler diagnostic on master and this branch.

### Promote/hold/kill prior

Predict **promote**, including `Schedule.t` slimming, if native and JS gates are
green (apart from the unchanged known signal failure), the parity suite closes
every obligation, and no real tap use requires schedule-local composition that
the call-site observers cannot express. Hold the slimming only if such a tap use
is found; kill only if the fixed signatures cannot preserve the required loop or
cancellation semantics.

---

## Execution log

### Step 1 — seal predictions

This section was committed before API or implementation edits.

### Step 2 — docs-first contract blocked before edits

The fixed signatures put every optional argument after all required arguments.
That shape is not erasable in OCaml 5.2.0+ox. Three Nix/OxCaml probes were run
before changing any `.mli`:

1. Defining the signatures literally produces Warning 16 for
   `?max_concurrent`, `?on_retry`, `?or_else`, and `?on_repeat`:
   `unerasable-optional-argument`.
2. Moving the optionals before the leading positional argument makes omission
   work, but the implementation does not match an interface containing the
   sealed exact arrow order.
3. Suppressing Warning 16 allows the literal library definition to compile,
   but the intended ordinary call is partial:

   ```text
   Error: This expression has type
            "?max_concurrent:int -> int list X.effect"
          but an expression was expected of type "int list X.effect"
   Hint: This function application is partial,
         maybe some arguments are missing.
   ```

Runnable reproducer: `contract-blocker/probe.sh`. The smallest technically
working correction is to put each optional before a following positional
argument, for example:

```ocaml
val map_par :
  ?max_concurrent:int ->
  'a list ->
  f:('a -> ('b, 'err) t) ->
  ('b list, 'err) t
```

Labeled-argument commutation preserves the desired full call spelling
`Effect.map_par values ~f ~max_concurrent:8`, but this changes the public arrow
order and partial-application contract. The objective says the displayed
signatures are the contract, so making that correction silently would not
follow the assignment exactly. A trailing `unit` would also erase the options
but would change the required call spelling. Requiring every omission to be
written `?max_concurrent:None` / `?on_retry:None` is the rejected silent-default
workaround, not the requested API.

**Status:** genuine blocker requiring the objective owner to authorize an OCaml-
erasable arrow order (or a different call shape). No production API, test, doc,
or implementation file was edited.

### Independent `Schedule.t` slimming hold trigger

The tap census exposed one existing use that the fixed E24 observers cannot
express: `Resource.auto` drives hook-bearing schedules in a background daemon.
The current public contract in `lib/eta/resource.mli` is, verbatim:

```ocaml
val auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:(unit, 'schedule_out, (unit, 'err) Effect.t) Schedule.t ->
  unit ->
  (('a, 'err) t, 'err) Effect.t
```

Its documented behavior is also explicit: “Effectful schedule taps run in the
refresh daemon; tap failures fail that schedule-driving effect normally rather
than being recorded as refresh failures.” The parity test is
`test/core_common/resource_common_suites.ml` lines 217–243. It observes the
runtime clock before the first schedule delay. `Resource.auto` has no refresh
observer argument; `?on_error` only observes loader failures. Neither
`Effect.retry.?on_retry` nor `Effect.repeat.?on_repeat` is a call site here.

Per the objective's hold rule, this was recorded without moving the tap into the
loader, weakening the test, or inventing a new `Resource.auto` argument. Such a
move would observe the initial load or a different lifecycle point and would not
preserve the contract. **Separate verdict: hold `Schedule.t` slimming pending an
authorized observer contract for this driver.**

`Eta_stream` also publicly drives hook-bearing schedules (`from_schedule`,
`schedule`, `repeat`, and `retry`). Some `Stream.schedule` input taps can be
expressed with upstream `Stream.tap`, but that does not resolve the independent
`Resource.auto` trigger and was not used as a workaround.

### Gates and later protocol steps

The production gates, requested parity suite, E24 runtime red-team probes, and
blinded A/B review packet were not run/generated: all require a compilable public
contract first. Running the unchanged baseline gates would not prove E24. The
contract reproducer is the highest-value failing gate at this point.
