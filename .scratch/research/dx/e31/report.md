# DX-E31 Report — `[@@eta.trace]` promote-trigger measurement

## Decision question and evidence boundary

The only promotion trigger is whether reviewers **still ask for function-level
trace sugar after E7/E8**. Technical feasibility, implementation effort already
spent elsewhere, and hypothetical future discovery are not demand evidence.
Under V-DX-PRINC-1, absence of in-repo use is not dispositive for a library, but
external-consumer need must have a structural forcing function.

## Forcing-function analysis

“Neutral” means the experiment neither requires nor materially replaces
function-definition `Effect.fn __POS__ __FUNCTION__` wrapping. “Less” means it
reduces the eligible use case or makes E10's fixed wrapper less applicable.

| Experiment | Direction | One-line evidence |
| --- | --- | --- |
| E7 — `[@@deriving eta_error]` | **Less / no forcing function** | E7 makes generated `error_pp` wiring explicit through `Effect.named`/`Effect.fn`; E10's no-keyword wrapper cannot carry `~error_pp`, so E7's 23 converted sites do not create eligible sugar demand (`e7/report.md:19,46-54`). |
| E8 — `[%eta.result]` | **Less (material)** | E8 directly expands to `Effect.fn __POS__ __FUNCTION__ (Effect.named ... (Effect.sync_result ...))` and converted 12 named typed-result leaves, absorbing the boilerplate that motivated definition sugar (`e8/report.md:5-18,40-48`). |
| E9b — sequential `and*` / explicit `Effect.par` | **Neutral** | It changes product sequencing/concurrency spelling at composition sites, not function-boundary tracing (`e9b/report.md:24-38`). |
| E13 — `Effect.async` | **Neutral** | It adds one callback-shaped construction leaf and explicitly found no application migration candidate; it does not force per-function spans (`e13/report.md:10-21,120-138`). |
| E15 — `Effect.interruptible` | **Neutral** | It adds dynamic cancellation restoration around checkpoints; the contract concerns same-fiber mask semantics, not definition instrumentation (`e15/report.md:7-36,305-312`). |
| E19 — scoped capability overrides | **Neutral** | Four dynamic service-substitution combinators scope clock/random/logger/tracer behavior without requiring a function-level wrapper (`e19/report.md:3-18`). |
| E20 — log/metric interception | **Neutral** | Interceptors alter per-subtree observability pipelines and remain held on allocation; neither their lexical placement nor result type forces `fn` at definitions (`e20/report.md:3-18,54-72`). |
| E22 — executable `.mli` laws | **Neutral** | It adds a test/registry policy for normative public contracts; it creates evidence obligations for any new prose but no consumer need for trace sugar (`e22/report.md:3-12`). |
| E23 — Result-mirroring error channel | **Neutral** | Renames/absorbs typed-error combinators and reduces the handle cluster; it does not alter tracing boundaries (`e23/report.md:3-16,35-45`). |
| E24 — List-shaped iteration and labeled schedules | **Neutral** | It reshapes collection and schedule-driver calls (`map_par`, `retry`, `repeat`) while preserving the tracing primitive (`e24/report.md:3-17`). |
| E25 — family-consistency renames | **Neutral, with narrower sugar fit** | `named ?kind ?error_pp` and `fn`'s optional rendering surface make explicit observability configuration uniform; E10's fixed no-keyword form would not express those options (`e25/report.md:3-18,49-62`). |
| E26 — `Effect.fresh` | **Neutral** | A runtime-local monotonic ID source is an effect leaf, not a repeated function-boundary tracing requirement (`e26/report.md:3-14`). |
| E27 — deferred formatter logging | **Neutral** | `logf` changes when formatting executes inside the logging pipeline; it creates no structural reason to wrap enclosing function definitions (`e27/report.md:3-18,28-44`). |
| E28 — unified `all` / `map_par` admission | **Neutral** | It unifies bounded collection scheduling while retaining input-shape distinctions; no tracing boundary changes (`e28/report.md:182-204`). |
| E29 — `par3` / `par4` | **Neutral** | Flat heterogeneous concurrent products remove nested tuples at call sites; inherited `par` semantics do not require definition-level spans (`e29/report.md:37-65,75-110`). |
| E30 — `Eta_js.from_js_promise` | **Neutral** | The JS adapter centralizes promise settlement/cancellation over `Effect.async`; its forcing function is host interop, not function trace decoration (`e30/report.md:24-65,178-197`). |

## Forcing-function verdict

No post-E10 experiment creates a structural need for function-level trace
sugar. E8 materially reduces the need by owning the common named typed-result
leaf shape. E7 and E25 also show a limitation of the fixed wrapper: meaningful
`error_pp`/kind/attribute configuration still needs the explicit primitive.

The consumption-model rescue therefore does not activate. External applications
could choose more function-level spans, but no promoted contract forces them to
do so, and “consumers may want it later” is not observable evidence.

## Cohort material (verbatim)

<!-- COHORT MATERIAL START -->
### Decision requested

Eta currently spells a function-boundary tracing span explicitly as:

```ocaml
let load_user id =
  Effect.fn __POS__ __FUNCTION__ (body id)
```

The proposed feature would replace that wrapper at function definitions with
exactly one sugar spelling, either:

```ocaml
let%eta load_user id = body id
```

or:

```ocaml
let load_user id = body id [@@eta.trace]
```

In either form, `body id` must already return `Effect.t`. The form adds the
current function name and source location span; it does not lift ordinary OCaml
code into an effect. Recursive functions create a span on each call. Optional
`fn` configuration such as `~kind`, `~error_pp`, and `~attrs` remains an explicit
`Effect.fn` use.

The trigger is not “could this work?” It is: **do reviewers still explicitly ask
for this sugar after E7/E8?**

### Measured demand

- Current executable census: **4 exact `Effect.fn __POS__ __FUNCTION__` sites in
  2 files**.
- All four are framework tests: three hand-written parity oracles for
  `[%eta.result]`, and one direct test of `Effect.fn`'s name/location contract.
- **0 of 4 are function bindings eligible for the proposed sugar.**
- **0 are consumer-shaped application sites.**
- A broad textual search adds one application-shaped README example, but it binds
  a local effect value rather than a function and is also ineligible.
- No experiment promoted after the hold creates a structural need for
  definition-level trace sugar.
- E8 reduces demand: `[%eta.result "name" body]` owns the common named typed-result
  leaf shape, including its function/source wrapper.

### Candidate verdict: FIRE — strongest case

The repository is a library implementation and test corpus, not a representative
sample of downstream applications. Application authors may reasonably put spans
at effect-returning service-function boundaries even though Eta's own machinery
does not. The explicit wrapper repeats two compiler-provided tokens and obscures
the function body. A single visible definition annotation would make that policy
concise, while the existing explicit primitive remains available for configured
spans. If this is a pattern you would actively choose in ordinary Eta
applications, explicitly request **FIRE** and choose one spelling.

### Candidate verdict: NO-FIRE — strongest case

The post-E7/E8 evidence contains no eligible consumer site and no structural
forcing function. The common named typed-result leaf boilerplate is already
covered by `[%eta.result]`; configured spans still need explicit `Effect.fn`.
A new definition form also introduces two predictable comprehension costs:
readers may think it lifts a plain body, and may think recursive definitions get
one span rather than one per call. Shipping syntax for hypothetical downstream
preference, without an observed or structurally forced use, fails the gate. If
you would not actively request the form on this evidence, choose **NO-FIRE**.

### Response format

1. `FIRE: let%eta` or `FIRE: [@@eta.trace]` — only if you explicitly want the
   sugar after considering the evidence; briefly say why.
2. Otherwise `NO-FIRE`; briefly state which evidence controls.

Do not choose FIRE merely because the transformation seems technically simple.
<!-- COHORT MATERIAL END -->
