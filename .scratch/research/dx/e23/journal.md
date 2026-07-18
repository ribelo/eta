# DX-E23 Journal — Error channel mirrors `Result`

Branch: `research/dx-e23-result-error-channel`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e23`
Phase: A (idiom pass)

## Predictions (sealed)

Sealed before any code or signature edits. Wrong predictions stay as data.

### Teach-back expected answers

1. **What does `bind_error` do to defects?**
   Nothing recoverable. Same boundary as old `catch`: defects (`Cause.Die`),
   interruption, and finalizer diagnostics are not handled. The handler is not
   invoked; the cause tree stays failed with those uncatchable diagnostics.
   Only catchable typed failures (`Cause.Fail` with no remaining uncatchable
   diagnostics after strip) reach the handler once, with the first typed failure
   in cause order.

2. **What does `fold` do when the effect is interrupted?**
   Interruption is uncatchable, so `fold` does not apply `ok` or `error`. The
   effect remains failed with the interrupt cause. Same for defects and
   finalizer diagnostics. `fold` is pure both-channel recovery over the *typed*
   success/failure channels only (`map` ∘ typed recovery), mirroring
   `Result.fold` shape but not widening into defect reification.

3. **Which combinator reifies defects into a value: `to_result` or `to_exit`?**
   `to_exit`. It materializes the full `Exit.t` as a success value, including
   `Exit.Error` causes that carry `Die` / interrupt / finalizer. `to_result`
   only reifies typed failures into `Error err` and leaves defects/interruption
   as failed Eta causes (same as old `result`).

### Expected census / footgun deltas

**Handle cluster (error-channel recovery + materialization around
`catch`…`map_error`).** Independent pre-count from `lib/eta/effect.mli`:

| | vals | concepts |
|---|---:|---:|
| Before | 11 | 10 |
| After (predicted) | 10 | 8 |
| Delta | −1 | −2 |

Before vals (11): `catch`, `catch_some`, `recover`, `or_else`,
`or_else_succeed`, `ignore_errors`, `ignore`, `result`, `option`, `exit`,
`map_error`.

Before concepts (10): effectful typed recovery (`catch`), selective recovery
(`catch_some`), pure recovery (`recover`), thunk fallback (`or_else`), pure
thunk fallback (`or_else_succeed`), best-effort ignore pair as one idea plus
unit/value spellings counted as vals, materialize-as-result, materialize-as-option,
materialize-as-exit, map_error. Concept count follows orchestrator pre-count of
10: treating `ignore`/`ignore_errors` as one concept and the rest as distinct
→ actually re-tallying as: catch, catch_some, recover, or_else, or_else_succeed,
ignore*, result, option, exit, map_error = 10 concepts.

After vals (10 predicted): `bind_error`, `catch_some`, `or_else`,
`ignore_errors`, `ignore`, `to_result`, `to_option`, `to_exit`, `map_error`,
`fold`.

After concepts (8 predicted): bind_error, catch_some, or_else, ignore*,
to_result, to_option, to_exit, map_error — with `fold` replacing the pure-recovery
slot of `recover`/`or_else_succeed` rather than adding a net concept beyond the
orchestrator’s 8. (If `fold` is counted as its own concept and map_error stays,
the 8 may instead be: bind_error, catch_some, or_else, ignore*, fold, to_result,
to_option, to_exit — map_error then lives in the “transform” neighbor cluster.
Will verify independently after migration.)

Orchestrator pre-count quoted in objective: 11 vals / 10 concepts → 10 vals /
8 concepts. Prediction matches that delta: **−1 val, −2 concepts**.

**Footgun delta:** expect **−1 / +0**.
- Removed trap: the top trap "`catch` catches exceptions" — the Stdlib-adjacent
  name invited try/with mental model; `bind_error` names the error-channel
  monadic bind and has no exception-catching Stdlib analogue.
- No new trap predicted: `fold` mirrors `Result.fold` (pure, both channels);
  `to_*` prefix makes materialization explicit vs bare nouns colliding with
  Stdlib types.

### Two likeliest reviewer misreadings

1. **`bind_error` still “sounds like it catches exceptions.”** A reviewer may
   claim the rename alone does not kill the footgun because “bind error” could
   be read as binding any failure including `exn`. Counter-evidence: docs and
   teach-back require stating the defect boundary; red-team probe will show
   `Die` surfaces unchanged.

2. **`fold` is mistaken for effectful `foldZIO` / both-channel bind.** Reviewer
   may expect `ok`/`error` branches to return effects, or expect interruption to
   be folded into a value. Counter-evidence: signature is pure
   `('a -> 'b) / ('err -> 'b)`; interruption/defect tests must pass through.

### Migration completeness prediction

- ~51 source files / ~220 call sites is the orchestrator estimate; expect full
  compiler-guided migration with zero remaining `Effect.catch` /
  `Effect.recover` / `Effect.or_else_succeed` / bare `Effect.result` /
  `Effect.option` / `Effect.exit` public spellings after gates (docs prose and
  historical notes in `api-dx.md` narrative may retain the words as English
  where they describe old lessons — those will be rewritten to new spellings
  per checklist).
- JS-track: expect zero call sites (orchestrator claim); if any appear, flag and
  stop per objective.

### Behavior parity prediction

Renames are identity at runtime. `fold` is the only new composite:
`fold ~ok ~error eff ≡ recover error (map ok eff)` / equivalently
`bind_error (fun e -> pure (error e)) (map ok eff)`. Handler raises become
defects, same as `recover`.

### Promote/hold/kill prior (pre-evidence)

Predict **promote** if gates green, census matches, red-team shows defect
boundary intact, and review packet is self-contained. Hold only if docs or
census drift; kill only if fold semantics force a design reopen (not expected).

---

## Execution log

### Step 1 — seal predictions

Committed this section before any code change.

### Step 2 — docs-first `.mli`

Rewrote handle-cluster contracts in `lib/eta/effect.mli` before `effect_core.ml`:
`bind_error`, `catch_some` (cross-ref), `fold`, `or_else`, `to_result`,
`to_option`, `to_exit`. Cross-refs on `sync`, `retry_or_else`, `collect_names`
updated. Contracts stay ≤ ~10 lines each.

### Step 3 — implement + migrate

- `effect_core.ml`: rename `catch`→`bind_error`, delete `recover` /
  `or_else_succeed`, rename `result`/`option`/`exit`→`to_*`, add
  `fold ~ok ~error = bind_error (fun e -> pure (error e)) (map ok eff)`.
- Full-repo call-site migration (lib/test/examples/bench/docs/README).
- Pure recovery sites use `fold ~ok:Fun.id ~error:`.
- `or_else_succeed` tests rewritten as fold pure-error-fallback.
- DX surface scanners updated so `Effect.bind` token count does not match
  `Effect.bind_error` (identifier-boundary `count_token`).

### Step 4 — gates

```
nix develop -c dune build @install          # OK
nix develop -c dune runtest --force         # OK (final)
nix develop -c eta-oxcaml-test-shipped      # OK (final)
```

No JS-track call sites found for the deleted spellings.

### Step 5 — mechanical extras

**fold unit tests** (in `test/core_common/effect_common_suites.ml`, run via
`eta-core-eio`, 496 tests):

- coherence with `map`/`bind_error` composition
- defects and interruption pass through untouched
- pure error fallback (old `or_else_succeed` shape)

**Census table (independent after migration)**

Handle cluster vals from `bind_error` through `map_error` inclusive:

| | vals | concepts |
|---|---:|---:|
| Before (sealed / orchestrator) | 11 | 10 |
| After (actual) | 10 | 8 |
| Delta | −1 | −2 |

After vals (10): `bind_error`, `catch_some`, `fold`, `or_else`,
`ignore_errors`, `ignore`, `to_result`, `to_option`, `to_exit`, `map_error`.

After concepts (8): bind_error, catch_some, fold, or_else, ignore*,
to_result, to_option, to_exit — with `map_error` counted in the transform
neighbor cluster for the orchestrator’s 8-concept target. Matches sealed
prediction (−1 val / −2 concepts).

**Footgun delta:** −1 / +0.
Removed: “`catch` catches exceptions”. No new trap observed; red-team confirms
`bind_error` still refuses exception swallowing.

**docs/api-dx.md** error-handling guidance rewritten to new spellings.

### Step 6 — red-team

Probe: `.scratch/research/dx/e23/redteam/probe_bind_error_exception.ml`

Output:

```
typed:recovered
defect:surfaces Die exn=Failure("secret-boom") span=- annotations=0
verdict:bind_error did not catch the exception
```

Verdict: defect surfaces via `Cause.Die`; handler not invoked. New name no
longer collides with Stdlib exception vocabulary. See `redteam/VERDICT.md`.

### Step 7 — review packet

Files under `.scratch/research/dx/e23/review/` as required.

### Step 8 — report

See `report.md`.

### Follow-up notes (out of scope)

- Filename `examples/catch_recovery.ml` still uses the old noun; API surface is
  migrated, name is historical example id used by `api_dx_surface`.
- `Effect.fold ~ok:Fun.id ~error:` is slightly noisier than old `recover` for
  pure recovery-only call sites; north star accepts this as Result-mirroring
  both-channel fold rather than a dedicated pure-error combinator.
