# Eta-effect-services — algebraic effects as a service substrate

Worktree: `../Eta-effect-services`
Branch:   `research-effect-services`
Lab:     `scratch/eta_research/effect_services/`
Status:   research only. No `packages/` edits.

## The question

Are OCaml 5 algebraic effects (`type _ Effect.t += ...` + handlers) a viable
mechanism for *some* services in Eta, and if so what observable rule classifies
a service as effect-suitable vs argument-passing-suitable?

The lab is **additive, not revisionist.** It does not reopen V-R5 (drop `'env`
channel) and it does not reopen V-Native-Effects (replace runtime AST with
native handlers). Both decisions stand. The hypothesis here is whether
algebraic effects earn their keep as an opt-in service mechanism alongside
ordinary argument passing.

## Hypothesis space — steelmanned

Each candidate is a real position with a real defender. The lab does not knock
any of them down by label.

### A. Pure argument passing (current Eta, Eio convention)

Status quo. Services are ordinary OCaml values, threaded explicitly à la Eio's
`Stdenv`. Zero machinery, total transparency, every dependency visible at the
call site, LSP and type errors pinpoint.

The cost: cross-cutting concerns (a single `log` call from inside a hot loop;
a span around an arbitrary operation) require either (a) plumbing the service
through every intermediate frame, or (b) capturing it in a closure at the
outer frame. In a wide call graph this becomes per-function noise that does
not earn its visibility.

### B. Pure algebraic effects

Every service via `perform`. Handlers installed once at app boot. Uniform,
ambient by default. Mocking is a handler swap. No parameter pollution.

The cost: OCaml has no compile-time check for handler presence. Forgetting a
handler is an `Effect.Unhandled` runtime crash. Native handlers are
fiber-locality-sensitive (the `native_effects_pivot` lab proved they do not
propagate across `Eio.Fiber.both` re-entry). Stack traces through handler
discontinuities are harder to read.

### C. Hybrid by category (predicted verdict)

Effects for ambient / read-mostly / no-lifecycle services (Log, Time, Random,
Tracer). Values for owned / lifecycle-bound resources (Pool, Connection, File,
DB handle). The trap is a fuzzy boundary that becomes per-author taste rather
than a documented rule.

### D. Effects as sugar over values

Handler does an Hmap lookup; `perform` is shorthand for "fetch value from
ambient registry". Best of both, two mechanisms doing one job, plus the Hmap
on the runtime path.

**Predicted verdict: C.** The lab is designed to falsify it.

## The load-bearing prior negative result

`scratch/oxcaml_research/concurrency_model/h2_ws_probe/` and
`../Eta-native-effects/scratch/eta_research/native_effects_pivot/` already
proved that OCaml 5 native handlers **do not propagate across `Eio.Fiber.both`
re-entry.** That killed handlers as the runtime substrate.

It does not automatically kill them as the service substrate. A service is a
read-only ambient lookup, not a control-flow primitive — a parent fiber can
re-install handlers cheaply when forking, *if* Eio's fiber-creation API admits
that. P1 must re-test this question scoped to services.

If P1 fails, the lab closes there. No further probes, no rescue patterns.

## Probes — ordered hardest-first, stop-at-falsifier

### P0 — Prior art survey (read-only)

- Effekt language (algebraic effects + capability-based DI).
- Eff (the original).
- Koka (effect rows).
- Multicore OCaml stdlib examples (`Effect.Deep` / `Effect.Shallow`).
- Eio's `Fiber.with_binding` / FLS — already in OCaml 5, already in Eio. A
  potential answer to the propagation question.
- Eio design discussion: why values were chosen over effects for capabilities.
  This is the negative case study; the lab must understand the reasoning
  before claiming to overrule it.
- The two prior Eta findings cited above.

Output: `prior_art.md`.

### P1 — Locality (HARD FALSIFIER)

Install one handler at the program root (e.g. `Log_info : string -> unit`).
Inside the handler-protected scope, exercise:

- `Eio.Fiber.both` with a `perform Log_info "..."` in each branch.
- `Eio.Fiber.fork ~sw`.
- A nested `Switch.run`.
- `Effect.timeout` (Eta's primitive).
- Eta's `Supervisor.scoped` with two children.
- Eta's `Effect.acquire_release` body and release.

For each, record: does the handler propagate? If not, what does it cost (in
LOC and ergonomics) to re-install at the fork point? Is there a single
wrapping primitive that covers all of them?

**Stop condition:** if propagation is broken AND no acceptable wrapping
primitive exists (acceptable = ≤ one well-named function call per fork site),
the hypothesis is dead. Record verdict, stop.

Output: `p1_locality/results.md`.

### P2 — Composition

Two libraries each declare an independent service effect:

```ocaml
type _ Effect.t += Log_info : string -> unit Effect.t
type _ Effect.t += Trace_span : string * (unit -> 'a) -> 'a Effect.t
```

Application boot installs both handlers. Stress: how does this scale to N
libraries and N services? Does the boot wall become unreadable? Does a third
library that declares its own service compose without coordination? Compare
to: a record-of-services value passed once.

Output: `p2_composition/results.md`.

### P3 — Cancellation interaction

A `perform` issued during:

- the body of an `Effect.acquire_release` cleanup,
- a fiber that has already received cancellation,
- a finalizer running under `Supervisor.scoped` teardown.

Does the handler still resolve? Does cleanup complete? Does the cancellation
cause re-raise behave consistently with Eta's existing finalizer rules?

This connects directly to the deadlock pattern the journal already documented
for blocking finalizers. The lab must verify effect-handler services do not
reintroduce that class of bug.

Output: `p3_cancellation/results.md`.

### P4 — Unhandled-effect failure mode and mitigation

What does forgetting to install a handler look like in practice? `Effect.Unhandled` at the moment of `perform`. Trace quality? Recovery path?

Probe candidate mitigations and rate each:

- A startup check: at app boot, perform-and-discard each declared service
  effect inside an outermost handler that records "seen". Crash early if a
  declared service is missing.
- A ppx that registers service-effect declarations and emits the boot check.
- A `module type SERVICE` convention with a runtime registry.
- "None of the above; document the convention and trust the user."

The bar: an ergonomic, loud failure mode at startup — not at the first
unlucky `perform` ten minutes into a production run.

**Stop condition:** if no mitigation produces a startup-time loud failure
without disproportionate machinery, the hybrid hypothesis weakens
substantially. Record and continue, but flag the verdict.

Output: `p4_unhandled/results.md`.

### P5 — DX comparison on a real-shape consumer

Express the same workload twice. The fixture must be small but real-shaped: a
function performing N HTTP-style attempts with retry, emitting log entries on
each attempt and a tracer span around the whole call. Services exercised:
`Log`, `Time` (for backoff), `Random` (for jitter), `Tracer`.

- Variant A: argument-passing. Services as a record threaded through.
- Variant B: effect-handler. Services performed inline, handler installed at
  the fixture root.

Compare:

- call-site noise (what does the inner attempt loop look like?),
- type signatures of intermediate helpers,
- test setup (what does the test file look like?),
- behavior on missing service,
- traceability (stack trace clarity at the inner failure point),
- composability (adding a fourth service later).

This is the diagnostic probe, not the flattering probe. Both variants must be
written carefully. The variant the author dislikes must still get its best
form.

Output: `p5_dx/{variant_a.ml, variant_b.ml, results.md}`.

### P6 — Mocking ergonomics

The same fixture from P5, with `Log` and `Time` replaced by deterministic
mocks. In Variant A, mocks are passed values. In Variant B, mocks are
handler bodies wrapping the test scope. Compare:

- LOC of test scaffolding,
- whether the mock can assert call-order without extra machinery,
- failure mode when the mock is forgotten,
- whether the mock leaks across test cases.

Output: `p6_mocking/results.md`.

### P7 — Boundary criteria definition

The output of P1–P6 is a documented rule:

> *Service S belongs as an effect iff it satisfies criteria {…}.
>  Otherwise S is a value.*

Candidate axes the lab will evaluate (the actual rule comes from evidence,
not this list):

- **Lifecycle:** does S have an acquire/release shape? (yes → value)
- **Cardinality:** is there at most one S per app? (yes → effect candidate)
- **Statefulness:** is S read-mostly ambient? (yes → effect candidate)
- **Locus of substitution:** does substitution happen at app boot, at a
  scope, or at a single call site?
- **Cross-cutting:** does S appear in many call frames at variable depth?
  (yes → effect candidate)
- **Mockability:** does mocking require call-order assertions or stateful
  doubles?

The verdict is the rule, written as observable criteria, not aesthetic ones.

Output: `p7_boundary/adr.md`.

### P8 — DI sketch (only if P1–P7 favorable)

If the rule from P7 produces a non-empty effect-suitable category and P1–P4
admit acceptable mechanics, sketch what an opt-in `Effect.Service`-style
utility would look like:

- declaration shape,
- handler installation API,
- startup-check mechanism (from P4),
- documented boundary rule (from P7),
- at most one worked example.

This is a derivative finding, not an independent probe. If the rule is
empty, P8 does not run.

Output: `p8_di/sketch.md`.

## Out of scope (declared up front)

- Replacing the runtime AST with native handlers — settled by V-Native-Effects.
- Reopening V-R5 (no `'env` channel). The hypothesis here is *additive*: keep
  argument passing as the default; study whether effects complement it for a
  specific class of service.
- Cross-domain handler propagation (OxCaml capsules, `Eta.island`). If the
  mechanism works in same-domain Eio, that is the v1 bar; cross-domain is a
  follow-up if anyone needs it.
- Replacing Eta's existing capability conventions (`Capabilities.clock`,
  `Capabilities.random`). The lab may *propose* moving some of these to
  effects, but the move itself is a follow-up task, not a deliverable here.
- Building production code. No edits under `packages/`. The lab is `scratch/`
  only.

## Acceptance criteria

1. `OBJECTIVE.md` (this file) and `scratch/eta_research/effect_services/README.md`
   exist at the listed paths.
2. P0 (prior art) and P1 (locality) have produced runnable evidence and
   results files.
3. If P1 fails, the lab closes with a recorded verdict and `results.md` stating
   what would change the verdict. No further probes run.
4. If P1 passes, P2–P7 each produce evidence and a results file. P8 runs iff
   the P7 rule is non-empty.
5. The final verdict explicitly answers:
   - which Eta services should be exposed via effects,
   - which stay as values,
   - the rule that produced the split,
   - what evidence would overturn the rule.
6. No edits under `packages/` from this worktree. The lab is research only.
7. A single ADR `scratch/eta_research/effect_services/adr.md` records the
   verdict.

## Stop conditions (no cargo-culting)

- **P1 fails (locality unfixable):** close, record verdict, archive findings.
- **P3 fails (effects re-introduce the finalizer-deadlock class of bug):**
  close, record verdict.
- **P4 fails (no acceptable startup-time loud failure):** continue, but the
  verdict for hybrid candidate C is downgraded — effects are not safe enough
  for production ambient services without a compile-time guard.
- **P5+P6 show effects strictly worse on every axis for every service
  category:** verdict goes to A; hypothesis C is rejected; no DI sketch.

## What the lab will not produce

- A new public Eta primitive. The deliverable is a verdict + ADR. Any
  primitive that the verdict implies is filed as a follow-up task.
- Performance numbers. P5 is about DX, not benchmarks. Effect-handler
  microbench is already covered by `native_effects_pivot`.
- A migration plan for existing Eta consumers. Out of scope.

## References

- `journal.md` §§ "R-channel re-evaluation" (V-R1..V-R4) and "R-channel
  reassessment" (V-R5..V-R7) — prior services research, settled the value-
  passing default. This lab is additive, not revisionist.
- `../Eta-native-effects/scratch/eta_research/native_effects_pivot/` — the
  load-bearing prior negative result on handler locality.
- `scratch/layer_research/` and `scratch/provide_survival/` — the prior
  Layer / `provide` falsifier labs. The candidate space studied there did
  *not* include native algebraic effects as a service mechanism, which is
  why this lab exists.
- Effekt language papers, multicore OCaml `Effect` stdlib documentation,
  Eio `Fiber.with_binding` / FLS — to be surveyed in P0.
