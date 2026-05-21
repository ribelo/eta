# Effet contract to OxCaml feature mapping

Status: migration-planning inventory. This is not a recap of the existing OxCaml verdict; it is an invariant map for the current Effet packages and their likely mode/static-safety probes.

Scope read: `packages/effet/`, `packages/effet-stream/`, `packages/ppx_effet/`, `packages/effet-otel/`, `packages/effet-schema/`, `journal.md` V-OxCaml/V-OxCaml-2/V-OxCaml-Perf/V-Rs/V-Sh/V-Diag/V-CD/V-LM/Schema/Capabilities entries, and `scratch/oxcaml_research/{results.md,fixtures/,effet_portable_probe/,effet_resource_probe/}`.

## Summary table

| ID | Name | Source | OxCaml feature | Difficulty | Risk |
| --- | --- | --- | --- | --- | --- |
| I-01 | Whole `Effect.t` AST must be either same-domain or portable-by-construction | `packages/effet/effect.ml:1-68`; `packages/effet/effect.mli:265-338` | portability, contention, kind annotation, layout | moderate | medium |
| I-02 | Callback captures inside AST nodes must obey the target runtime boundary | `packages/effet/effect.ml:4-12,25-30,34-44,57-68`; `packages/effet/effect.mli:57-63,111-120,291-304` | `@@ portable`, once, kind annotation | moderate | medium |
| I-03 | `acquire_release` release runs at most once for an acquired value | `packages/effet/effect.ml:37-39,139`; `packages/effet/runtime.ml:384-395` | once | trivial | low |
| I-04 | Scoped switches and finalizer stacks cannot escape their lexical Eio region | `packages/effet/runtime.ml:396-411,885-892` | locality, local_ | moderate | low |
| I-05 | Supervisor child handles cannot escape the nursery | `packages/effet/supervisor.mli:1-66`; `packages/effet/effect.ml:70-108` | locality, rank-2 replacement, local_ | moderate | low |
| I-06 | Eio-fiber concurrency is not domain-parallel execution | `packages/effet/runtime.ml:310-378,675-784` | portability split, contention | moderate | medium |
| I-07 | Runtime-owned typed failure keys make `Obj.t` unpacking slot-safe | `packages/effet/runtime.ml:5-8,34-49,63-78` | capsule/unique, something else | speculative | medium |
| I-08 | Finalizer causes are protected, aggregated, and suppress primary failures correctly | `packages/effet/runtime.ml:224-254,384-401` | once, locality, portability of cause payload | moderate | low |
| I-09 | Runtime fiber-local trace and die context propagates across fibers | `packages/effet/runtime.ml:10-32,414-488,530-585`; `packages/effet/tracer.ml:63-88` | portability of payload, locality of context | moderate | medium |
| I-10 | `Cause.Die` diagnostics are inspectable without a tracer and need portable boundary form | `packages/effet/cause.mli:20-35`; `packages/effet/runtime.ml:51-61,165-216` | portability, kind annotation | moderate | medium |
| I-11 | Cause tree structure preserves failure algebra, not plain `result` | `packages/effet/cause.ml:10-48`; `packages/effet/exit.ml:1-13` | portable payload kinds, immutable_data | trivial | low |
| I-12 | Runtime daemons are runtime-owned and `drain` tracks finite background fibers | `packages/effet/runtime.ml:80-93,791-807,902-905` | atomic kind, locality | moderate | medium |
| I-13 | Supervisor failure list and child cancellation are mutation-safe under sibling fibers | `packages/effet/effect.ml:100-108,332-338`; `packages/effet/runtime.ml:610-673` | Atomic, Capsule, contention | moderate | medium |
| I-14 | Resource cache updates only after successful loads and keeps last-good on refresh failure | `packages/effet/resource.ml:1-47` | Portable.Atomic, Capsule, contention | moderate | low |
| I-15 | `Schedule.t`/`Duration.t` are pure schedule descriptions except jitter randomness | `packages/effet/schedule.ml:1-73`; `packages/effet/duration.ml:1-28` | portable kind, immutable_data | trivial | low |
| I-16 | Trace context is validated W3C data and should remain pure/portable | `packages/effet/trace_context.ml:1-113`; `packages/effet/capabilities.mli:44-61` | portable kind, immutable_data | trivial | low |
| I-17 | In-memory tracer state is mutable, fiber-local, and runtime-local | `packages/effet/tracer.ml:34-88,100-217` | locality, Capsule, atomic kind | speculative | medium |
| I-18 | In-memory logger/meter buffers are same-domain collectors | `packages/effet/logger.ml:18-32`; `packages/effet/meter.ml:18-35` | Atomic/portable collector split | moderate | low |
| I-19 | Span metadata nodes carry only propagation-safe data | `packages/effet/effect.ml:45-56,157-183`; `packages/effet/capabilities.mli:44-70` | portability, immutable_data | trivial | low |
| I-20 | `Log` and `Metric_update` payloads are lazy runtime-scoped signals | `packages/effet/effect.ml:57-68,185-190`; `packages/effet/runtime.ml:508-528` | portability, kind annotation | moderate | low |
| I-21 | `run`, `run_exn`, and `drain` are same-domain interpreter entry points today | `packages/effet/runtime.mli:17-33`; `packages/effet/runtime.ml:873-905` | portable runtime sibling, local runtime | moderate | medium |
| I-22 | Stream AST callbacks must match the same-domain or portable stream runtime | `packages/effet-stream/effet_stream.ml:44-81,203-280` | portability, `@@ portable`, kind annotation | moderate | medium |
| I-23 | Stream concurrent transport is Eio-queue backed and nonportable across domains | `packages/effet-stream/effet_stream.ml:281-376,382-593` | portable sink, Atomic, contention | moderate | medium |
| I-24 | Stream file errors preserve original `exn`; portable diagnostics need a separate shape | `packages/effet-stream/effet_stream.mli:16-26,74-100`; `packages/effet-stream/effet_stream.ml:169-185,293-334` | portability boundary, immutable diagnostic | moderate | medium |
| I-25 | PPX-generated leaves must not hide env capture or duplicate capability bindings | `packages/ppx_effet/ppx_effet.ml:25-105,107-155` | generated mode annotations, portability | moderate | low |
| I-26 | OTel exporter mutable tables and queues are runtime-local, not domain-portable | `packages/effet-otel/effet_otel.ml:391-411,436-488,604-658` | locality, Capsule, portable queues | speculative | medium |
| I-27 | OTel callbacks and encoders should separate portable payload encoding from Eio export | `packages/effet-otel/effet_otel.ml:49-174,196-356,421-434,675-710` | portability, once, atomic kind | moderate | low |
| I-28 | Schema values are pure; effectful policies are the only env-row boundary | `packages/effet-schema/effet_schema.mli:89-235`; `packages/effet-schema/effet_schema.ml:220-689` | portable kind, immutable_data | moderate | low |
| I-29 | Schema adapters isolate external JSON modes from core schema values | `packages/effet-schema/effet_schema.mli:238-262`; `packages/effet-schema/effet_schema.ml:692-717` | portability boundary, kind annotation | trivial | low |
| I-30 | Capabilities env channel is object-row requirements, not provide/layer state | `packages/effet/capabilities.mli:1-23,25-140`; `journal.md:5245-5493,6320-6640` | object modes, portability of objects | speculative | high |
| I-31 | Samplers are closure records; portable runtimes need portable sampler callbacks | `packages/effet/sampler.ml:1-30`; `packages/effet/runtime.ml:85,429-432,553-556` | `@@ portable`, kind annotation | trivial | low |
| I-32 | `Private.view` relies on representation identity and abstract-constructor discipline | `packages/effet/effect.ml:248-328` | layout, unboxed/mixed block, kind annotation | speculative | medium |
| I-33 | Heterogeneous `par`/`race` casts are slot-local and must stay hidden | `packages/effet/runtime.ml:326-344,705-756` | unique/capsule, layout | speculative | medium |
| I-34 | Error renderers are scoped captures used only at interpretation/observability time | `packages/effet/effect.ml:44,144,157-164`; `packages/effet/runtime.ml:129-163,412-413` | `@@ portable`, kind annotation | trivial | low |
| I-35 | Public precondition checks remain dynamic unless promoted to typed APIs | `packages/effet/effect.ml:126-128,175-178`; `packages/effet-stream/effet_stream.ml:99-109`; `packages/effet/cause.ml:24-33`; `packages/effet/runtime.ml:715-744` | type-level naturals unlikely, runtime check | trivial | low |
| I-36 | Delay, timeout, retry, repeat use runtime-owned clocks and scheduler step refs | `packages/effet/runtime.ml:105-113,273-280,814-871`; `packages/effet/schedule.ml:41-73` | locality, portable RNG boundary | moderate | medium |
| I-37 | Cancellation maps to `Interrupt`; `Uninterruptible` protects only Eio cancellation windows | `packages/effet/effect.mli:104-110`; `packages/effet/runtime.ml:66-67,225-226,377-379,648-656` | locality, something else | moderate | low |
| I-38 | Ordered result collection is an interpreter invariant, not guaranteed by raw parallelism | `packages/effet/runtime.ml:310-378,675-784`; `packages/effet-stream/effet_stream.ml:382-593` | portable reducers, contention | moderate | medium |
| I-39 | Schema JSON/issue values are portable data, but numeric and source identity checks stay dynamic | `packages/effet-schema/effet_schema.ml:1-218,220-689`; `journal.md:8915-9075,9010-9075` | immutable_data, portable kind | trivial | low |
| I-40 | Capability object adapters may hide Eio resources behind pure-looking methods | `packages/effet/capabilities.ml:1-96`; `packages/effet/runtime.mli:3-15`; `packages/effet/effect.mli:7-15` | object modes, locality | moderate | high |
| I-41 | OTel metric aggregation is batch-local mutable state and must not become shared state accidentally | `packages/effet-otel/effet_otel.ml:196-356`; `packages/effet-otel/effet_otel.mli:50-61` | portable pure encoders, local Hashtbl | moderate | low |
| I-42 | `Trace_context.make` and stream/file builders encode boundary validation dynamically | `packages/effet/trace_context.ml:14-113`; `packages/effet-stream/effet_stream.ml:99-109,169-185` | something else, refined value types | trivial | low |
| I-43 | Tests and internal clocks rely on same-domain mutable fixtures, not library portability claims | `packages/effet/test/test_effet.ml:63-90,98-126`; `packages/effet-stream/test/test_effet_stream.ml:15-27` | none for public API; locality for test helpers | trivial | low |

## Constructor-by-constructor Effect AST audit

This table is the exhaustive constructor pass for the shipped core AST. It is intentionally lower-level than the invariant sections: it answers whether each constructor is pure data, callback-bearing, Eio/runtime-owned, or observability-only.

| Constructor | Source | Current contract | OxCaml candidate | API annotation need |
| --- | --- | --- | --- | --- |
| `Pure` | `effect.ml:2`; `runtime.ml:266` | trusts success payload `'a` | portable/immutable_data payload in portable AST | depends |
| `Fail` | `effect.ml:3`; `runtime.ml:267` | typed error payload `'err` | portable/immutable_data error in portable AST | depends |
| `Thunk` | `effect.ml:4`; `runtime.ml:268-272` | closure captures arbitrary env/state | `@@ portable` or local callback profile | yes for portable AST |
| `Bind` | `effect.ml:5-7`; `runtime.ml:273-275` | continuation called by interpreter protocol | portable callback; maybe `once` per interpretation | depends |
| `Map` | `effect.ml:8`; `runtime.ml:276-277` | mapper captures arbitrary state | portable callback | depends |
| `Catch` | `effect.ml:9-12`; `runtime.ml:278-293` | handler only sees typed `Fail` | portable callback plus fail-key invariant | depends |
| `Tap_error` | `effect.ml:13`; `runtime.ml:294-307` | side-effect observer then re-fail | local or portable observer; likely nonportable by default | depends |
| `Delay` | `effect.ml:14`; `runtime.ml:308-310` | runtime sleep capability owns time | local runtime clock; portable duration data | no for existing |
| `Timeout` | `effect.ml:15-17`; `runtime.ml:311-315` | Eio race between sleep and body | Eio-local; portable runtime needs own scheduler | yes for new runtime |
| `Concat` | `effect.ml:18`; `runtime.ml:316-322` | ordered sequential unit children | portable list if children portable | depends |
| `Race` | `effect.ml:19`; `runtime.ml:323-324,713-756` | first success wins; failures aggregate | portable race combinator plus typed winner slot | yes for domain runtime |
| `Par` | `effect.ml:20-22`; `runtime.ml:325-344` | Eio fibers, heterogeneous slot casts | portable fork/join; unique slot tokens | yes for domain runtime |
| `All` | `effect.ml:23`; `runtime.ml:345-352` | concurrent, input-order results, fail-fast | portable reducer preserving order | yes for domain runtime |
| `All_settled` | `effect.ml:24-26`; `runtime.ml:353-356` | collect every child as result/cause | portable `Cause` and ordered result array | yes for domain runtime |
| `For_each_par` | `effect.ml:27-29`; `runtime.ml:357-364` | callback builds child effect per item | portable callback and item payload | depends |
| `For_each_par_bounded` | `effect.ml:30-32`; `runtime.ml:365-375` | dynamic max check; Eio semaphore | portable scheduler permits; type-level max not worth it | depends |
| `Daemon` | `effect.ml:33`; `runtime.ml:376` | private runtime-owned background fiber | local runtime handle; atomic active counter | no public |
| `Uninterruptible` | `effect.ml:34`; `runtime.ml:377-379` | `Eio.Cancel.protect` only | Eio-local cancellation region | no |
| `Repeat` | `effect.ml:35`; `runtime.ml:380-382,814-832` | schedule loop with mutable step refs | local step state; portable schedule data | no/depends |
| `Retry` | `effect.ml:36-38`; `runtime.ml:383-385,834-871` | predicate controls typed retry | portable predicate if domain runtime | depends |
| `Acquire_release` | `effect.ml:39-41`; `runtime.ml:386-395` | release finalizer registered once | `once` release | yes for portable API |
| `Scoped` | `effect.ml:42`; `runtime.ml:396-401` | fresh switch/finalizer stack | `local_` switch and finalizer stack | no public |
| `Supervisor_scoped` | `effect.ml:43-45`; `runtime.ml:402-411` | rank-2 body owns nursery | `local_` alternative; keep rank-2 until proven | depends |
| `Render_error` | `effect.ml:46`; `runtime.ml:412-413` | scoped renderer callback | portable/local callback | depends |
| `Named` | `effect.ml:47-49`; `runtime.ml:414-485` | span metadata + runtime tracer side effects | portable metadata, local tracer | no/depends |
| `Annotate` | `effect.ml:50`; `runtime.ml:489-497` | attrs copied into tracer and die context | portable string attrs | no |
| `Link_span` | `effect.ml:51-52`; `runtime.ml:499-501` | span link payload only | portable link data | no |
| `With_external_parent` | `effect.ml:53-54`; `runtime.ml:502-505` | external context installed fiber-locally | portable trace context, local binding | no |
| `With_context` | `effect.ml:55-56`; `runtime.ml:502-505` | same as external parent, newer API | portable trace context, local binding | no |
| `Current_span` | `effect.ml:57`; `runtime.ml:506-509` | inspect active span in tracer | local tracer; portable span_info mirror | depends |
| `Current_context` | `effect.ml:58`; `runtime.ml:510-521` | derive current W3C context | portable trace_context payload | no |
| `Log` | `effect.ml:59-61`; `runtime.ml:522-527` | lazy runtime-scoped log signal | portable payload; local/exporter sink | depends |
| `Metric_update` | `effect.ml:62-69`; `runtime.ml:528-529` | lazy runtime-scoped metric point | portable payload; local/exporter sink | depends |

## Per-invariant details

### I-01 — Whole `Effect.t` AST must be either same-domain or portable-by-construction

- Statement: the public abstract `('env, 'err, 'a) Effect.t` is a lazy GADT program. Every constructor payload in the 35-node view must either be treated as same-domain Eio data or be made portable under a future domain runtime: `Pure`, `Fail`, `Thunk`, `Bind`, `Map`, `Catch`, `Tap_error`, `Delay`, `Timeout`, `Concat`, `Race`, `Par`, `All`, `All_settled`, `For_each_par`, `For_each_par_bounded`, `Daemon`, `Uninterruptible`, `Repeat`, `Retry`, `Acquire_release`, `Scoped`, `Supervisor_scoped`, `Render_error`, `Named`, `Annotate`, `Link_span`, `With_external_parent`, `With_context`, `Current_span`, `Current_context`, `Log`, and `Metric_update`.
- Source location: `packages/effet/effect.ml:1-68`, public constructors hidden by `packages/effet/effect.mli:18`, re-exposed internally at `packages/effet/effect.mli:265-338` and `packages/effet/effect.ml:248-319`.
- Current enforcement: typed but unconstrained by modes; abstraction hides constructors from ordinary users, but `Private.view` deliberately exposes the full shape to runtime/package code. Existing OxCaml negative shows shipped `Effect.t` is nonportable.
- Candidate OxCaml feature(s): portable kind on a new portable AST, contention on env, immutable_data on success/error payloads, possibly layout annotations if representation work proceeds.
- Public API annotations: depends. Same-domain API can remain unannotated; `Runtime.run_parallel` or portable `Effect.Portable.t` would need public kind annotations.
- Difficulty: moderate.
- Risk of fighting Effet's idea: medium. Effet's current idea is one small GADT over Eio fibers; splitting portable/nonportable ASTs adds surface but matches the ZIO/domain-parallel direction.
- Probe shape: positive fixture extends `effet_redesigned_portable_positive.ml` from Pure/Thunk/Bind/Map to every constructor except Eio-only nodes; negative fixture attempts to cross `Parallel_scheduler` with each constructor capturing `ref`, `Eio.Stream.t`, `Eio.Switch.t`, or nonportable callbacks. Existing references: `scratch/oxcaml_research/fixtures/effet_redesigned_portable_positive.ml:7-63`, `scratch/oxcaml_research/effet_portable_probe/effet_real_t_portable_negative.ml:13-30`.
- Open questions: can the full recursive GADT receive one kind annotation, or does OxCaml force a split into portable/same-domain constructors? How should `Daemon`, `Scoped`, `Supervisor_scoped`, `Log`, and `Metric_update` be represented in a portable AST when their interpretation is runtime-local?

### I-02 — Callback captures inside AST nodes must obey the target runtime boundary

- Statement: every stored function is a delayed continuation/callback: `Thunk`, `Bind`, `Map`, `Catch`, `Tap_error`, `For_each_par`, `For_each_par_bounded`, `Retry` predicate, `Acquire_release` release, `Supervisor_bind`, `Render_error`, `named ?error_renderer`, stream maps, schema policies, samplers, OTel callbacks. In a domain runtime, these captures must be statically portable or deliberately local.
- Source location: core callback constructors at `packages/effet/effect.ml:4-12,25-30,34-44,57-68,75-77,94-98`; API at `packages/effet/effect.mli:57-63,111-120,127-140,151-159,176-186`.
- Current enforcement: typed function arrows only; captured mutable refs are trusted/audit-only. Existing fixture proves `@@ portable` rejects `ref` capture and accepts atomic capture.
- Candidate OxCaml feature(s): `@@ portable` on stored callbacks, once for release, kind annotation on closure-containing records.
- Public API annotations: depends. A portable API must expose portable callback requirements; current same-domain API should not.
- Difficulty: moderate.
- Risk: medium, because annotating all existing callbacks would reject common same-domain code. Prefer sibling portable constructors.
- Probe shape: positive: each callback captures only immutable data or `Portable.Atomic`; negative: each captures `int ref`. Start from `effect_ast_atomic_capture_positive.ml:1-12` and `effect_ast_portable_capture_negative.ml:1-10`, then add Bind/Map/Catch/Tap_error/Retry/Render_error.
- Open questions: can `Bind` be marked `once`? Effet's interpreter calls it once per node visit, but an AST value can be interpreted multiple times, so the closure itself is not globally once unless the portable runtime consumes the program linearly.

### I-03 — `acquire_release` release runs at most once for an acquired value

- Statement: after acquire succeeds, runtime registers one finalizer for that value and invokes it once when the current scope exits, including success, typed failure, defect, and cancellation paths.
- Source location: constructor/API at `packages/effet/effect.ml:37-39,139`; registration at `packages/effet/runtime.ml:384-395`; finalizer execution at `packages/effet/runtime.ml:224-254`.
- Current enforcement: runtime check/protocol plus tests; no type-level at-most-once guarantee. The finalizer list is a ref; release callback can still be called twice by buggy interpreter code.
- Candidate OxCaml feature(s): once on the release callback argument or on the interpreter's finalizer thunk.
- Public API annotations: yes for the portable API; possibly no for the same-domain API to avoid breaking callbacks reused in tests.
- Difficulty: trivial.
- Risk: low. `once` exactly names the existing contract.
- Probe shape: existing positive `acquire_release_once_positive.ml:5-11`; existing negative `acquire_release_once_negative.ml:11-20`. Next probe wraps real `Effect.acquire_release` in a small mode-annotated signature and verifies release cannot be called twice inside a mock interpreter.
- Open questions: does the public `release : 'a -> Effect.t` become `('a -> Effect.t) @ once`, or is the once function internal after `acquire_release` consumes it?

### I-04 — Scoped switches and finalizer stacks cannot escape their lexical Eio region

- Statement: `Effect.scoped`, `supervisor_scoped`, and top-level `run` create fresh Eio switches and finalizer refs whose lifetime must end with the lexical scope. Users must not retain an `Eio.Switch.t` or finalizer stack past closure.
- Source location: `packages/effet/runtime.ml:396-411` for scoped/supervisor switch creation; `packages/effet/runtime.ml:885-892` for top-level run switch/finalizer root.
- Current enforcement: Eio runtime detects use-after-close dynamically; rank-2 protects supervisor children, but not raw switches hidden in runtime internals.
- Candidate OxCaml feature(s): local_ on an Effet-owned switch alias; locality for finalizer stack tokens.
- Public API annotations: no for normal users; yes if an Effet-owned `Switch.t @ local` wrapper appears in `Private` or supervisor APIs.
- Difficulty: moderate due to Eio not yet declaring `Switch.t` local in public API.
- Risk: low. Locality matches Eio's intended switch lifetime.
- Probe shape: existing negative `switch_escape_local_negative.ml:10-21`; positive fixture with `with_scope (fun (sw @ local) -> fork/use only inside)`. Real probe should replace `Eio.Switch.t` in `Effect.Private.make_supervisor` with an Effet-local wrapper.
- Open questions: upstream Eio mode annotations vs Effet wrapper? Can `Eio.Fiber.fork ~sw` accept local switch handles ergonomically?

### I-05 — Supervisor child handles cannot escape the nursery

- Statement: a `('s, 'err, 'a) Supervisor.child` is usable only in the `scoped` body that minted phantom `'s`; it cannot be returned or stored outside the nursery.
- Source location: API doc and rank-2 body at `packages/effet/supervisor.mli:1-66`; core representation at `packages/effet/effect.ml:70-108`; interpreter at `packages/effet/runtime.ml:587-673`.
- Current enforcement: statically enforced by rank-2 polymorphism; no mode annotations. Runtime also cancels children when switch exits.
- Candidate OxCaml feature(s): local_ child handle as a simpler signature, while preserving rank-2 or replacing only after real probe.
- Public API annotations: depends. Keeping rank-2 requires no annotations; replacing it needs public local annotations.
- Difficulty: moderate.
- Risk: low if rank-2 remains; medium if replacing because the current API already works.
- Probe shape: existing toy positive `supervisor_local_positive.ml:1-8`; negatives `supervisor_local_return_negative.ml:1-7` and `supervisor_local_ref_negative.ml:1-9`. Next probe ports real `Supervisor.scoped` body to local child handle.
- Open questions: does local_ improve real compiler errors enough to justify changing the public API?

### I-06 — Eio-fiber concurrency is not domain-parallel execution

- Statement: `race`, `par`, `all`, `all_settled`, `for_each_par`, bounded traversal, and stream concurrent operators are Eio-fiber combinators inside one runtime. They must not be silently reinterpreted as domain-parallel APIs.
- Source location: core API `packages/effet/effect.mli:71-103`; runtime `packages/effet/runtime.ml:310-378,675-784`; stream concurrency `packages/effet-stream/effet_stream.ml:382-593`.
- Current enforcement: Eio runtime; no domain transfer. Existing OxCaml fixture shows `Eio.Stream.add` is nonportable in `Parallel.fork_join2`.
- Candidate OxCaml feature(s): portable sibling runtime backed by `Parallel_scheduler`; portable kind on programs; contention on shared payload/state.
- Public API annotations: yes only on a new parallel/domain API. Existing `par` stays fiber-local.
- Difficulty: moderate.
- Risk: medium. Reusing names for domain parallelism would fight Effet's current fiber semantics and Eio cancellation.
- Probe shape: positive `parallel_scheduler_smoke.ml:1-18` plus portable AST fixture; negative `parallel_ref_capture_negative.ml:1-16`; stream negative `stream_eio_queue_parallel_negative.ml:1-17`.
- Open questions: should `Runtime.run_parallel` require a fully portable AST, or should individual nodes opt into domain scheduling?

### I-07 — Runtime-owned typed failure keys make `Obj.t` unpacking slot-safe

- Statement: typed failures cross Eio fibers by packing `Cause.t` into `Raised_cause (key, Obj.t)` and unpacking only when the fresh frame key matches. The invariant is that no `Obj.obj` occurs under the wrong typed error channel.
- Source location: comment and exception at `packages/effet/runtime.ml:5-8`; key counter at `runtime.ml:34-44`; packing at `runtime.ml:46-49`; unpacking at `runtime.ml:63-65,285-290,299-304,857-867`.
- Current enforcement: runtime key equality plus module privacy. Uses `Obj.t`; trusted/audit-only for type soundness.
- Candidate OxCaml feature(s): capsule/unique token for fail key; existential package alternative; not clearly a mode feature.
- Public API annotations: no.
- Difficulty: speculative.
- Risk: medium. This is an internal performance/typing trick; over-modeling it in modes may complicate the runtime without user benefit.
- Probe shape: positive fixture packages a cause with a unique key and rejects unpack without key; negative attempts to store/use packed payload after key region expires. If modes do not help, document as an audited runtime invariant.
- Open questions: can unique/capsule express “only this interpreter frame may unpack” without rewriting the exception transport?

### I-08 — Finalizer causes are protected, aggregated, and suppress primary failures correctly

- Statement: finalizers run under cancellation protection; finalizer failures are collected concurrently; if the body failed, finalizer failure becomes `Suppressed { primary; finalizer }` rather than replacing it.
- Source location: `packages/effet/runtime.ml:224-254`; finalizer registration in `runtime.ml:384-395`; child scopes in `runtime.ml:396-411`.
- Current enforcement: Eio runtime plus interpreter protocol. Tests cover exactly-once and suppressed causes, but static modes do not.
- Candidate OxCaml feature(s): once for finalizer thunks, locality for finalizer stack, portable `Cause.t` if crossing domains.
- Public API annotations: mostly no; `acquire_release` release yes in portable API.
- Difficulty: moderate.
- Risk: low.
- Probe shape: positive fixture consumes each finalizer once and builds a portable cause tree; negative tries to run a `release @ once` twice or return the finalizer stack.
- Open questions: should finalizer stack be a unique resource rather than `list ref` in a portable runtime?

### I-09 — Runtime fiber-local trace and die context propagates across fibers

- Statement: active span id, sampled flag, W3C trace context, and die diagnostic context are stored in Eio fiber-local keys and inherited by child fibers; named/annotated defects must retain diagnostics even when spans are unsampled.
- Source location: fiber keys at `packages/effet/runtime.ml:10-32`; named/context interpretation at `runtime.ml:414-488`; auto-instrument leaves at `runtime.ml:530-585`; tracer context at `packages/effet/tracer.ml:63-88`.
- Current enforcement: Eio runtime dynamic context. Data payloads are typed records/lists; context inheritance is an Eio behavior, not statically visible.
- Candidate OxCaml feature(s): portable kind for context payload records; locality for dynamic context handles; maybe capsule for mutable tracer state.
- Public API annotations: no for same-domain; portable context API may annotate `trace_context` only.
- Difficulty: moderate.
- Risk: medium. Fiber-local dynamic state is central to current tracing; domain runtimes need a new propagation story.
- Probe shape: positive portable `trace_context` passed through domain tasks; negative stores nonportable baggage payload if representation is widened. Existing V-P tests already cover fiber inheritance; OxCaml probe should focus payload modes.
- Open questions: how does `Eio.Fiber.key` context map to `Parallel_scheduler` domains? Explicit context passing may be required.

### I-10 — `Cause.Die` diagnostics are inspectable without a tracer and need portable boundary form

- Statement: unchecked defects preserve `exn`, optional raw backtrace, span name, and annotations on the `Cause.Die` leaf, independently of tracer sampling/export.
- Source location: `packages/effet/cause.mli:20-35`, `packages/effet/cause.ml:3-16`; runtime capture `packages/effet/runtime.ml:51-61`; event conversion `runtime.ml:165-216`.
- Current enforcement: runtime capture and API type. `exn` and `Printexc.raw_backtrace` are not known portable across domains.
- Candidate OxCaml feature(s): portable diagnostic mirror record, kind annotation on `Cause.Portable.t`, immutable_data constraints on `'err`.
- Public API annotations: depends. General `Cause.t` likely remains unconstrained; cross-domain aggregation needs a portable cause type.
- Difficulty: moderate.
- Risk: medium. Replacing `exn` with strings everywhere would harm same-domain debugging.
- Probe shape: existing positive `cause_portable_positive.ml:1-12` with string stack; negative `cause_closure_negative.ml:1-4`. Add negative for raw `exn`/backtrace if OxCaml rejects them under portable kind.
- Open questions: what is the lossless-enough portable representation of `exn` and raw backtrace?

### I-11 — Cause tree structure preserves failure algebra, not plain `result`

- Statement: `Fail`, `Die`, `Interrupt`, `Sequential`, `Concurrent`, and `Suppressed` carry semantic structure that `('a,'e) result` cannot represent; `Exit.to_result` intentionally returns `None` for non-typed-fail causes.
- Source location: `packages/effet/cause.ml:10-48`; `packages/effet/exit.ml:1-13`.
- Current enforcement: type-level public API, with runtime checks converting empty sequential/concurrent to `Die (Invalid_argument ...)`.
- Candidate OxCaml feature(s): portable kind on tree with constrained payload; immutable_data on error payload.
- Public API annotations: depends on portable boundary.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive portable tree over immutable variants; negative tree over closure error payload.
- Open questions: should `Interrupt` ids remain ints, or become runtime-local/nonportable tokens if real identities are added?

### I-12 — Runtime daemons are runtime-owned and `drain` tracks finite background fibers

- Statement: only package-internal `Effect.Private.daemon` can fork runtime-owned finite background effects. The runtime active counter increments before daemon start, decrements in `finally`, and `drain` yields until it reaches zero.
- Source location: runtime record `packages/effet/runtime.ml:80-93`; daemon fork `runtime.ml:791-807`; drain `runtime.ml:902-905`; private daemon constructor `packages/effet/effect.ml:246,330`.
- Current enforcement: module privacy plus `Atomic.t`; daemon exceptions are swallowed.
- Candidate OxCaml feature(s): atomic kind for `active`; locality for `outer_sw`; portable runtime would need a different daemon pool.
- Public API annotations: no.
- Difficulty: moderate.
- Risk: medium because daemon semantics are Eio-specific.
- Probe shape: positive active counter with `Portable.Atomic` in portable runtime; negative daemon closure capturing Eio switch across domain.
- Open questions: should portable runtime have daemons at all, or require explicit scheduler ownership?

### I-13 — Supervisor failure list and child cancellation are mutation-safe under sibling fibers

- Statement: child result promise resolves once; cancellation requests racing with child startup are honored; child failures append to supervisor failure history; `check` observes `max_failures`.
- Source location: supervisor record `packages/effet/effect.ml:100-108`; accessors `effect.ml:332-338`; interpreter `packages/effet/runtime.ml:610-673`.
- Current enforcement: `Atomic.compare_and_set` for promise resolution; `Atomic` cancel flag; `ref` for child switch/cancel handles and failures list. Safe under Eio cooperative fibers; not domain-safe.
- Candidate OxCaml feature(s): Portable.Atomic for flags and failure history, Capsule/Mutex for list mutation, local_ for child switch.
- Public API annotations: no for rank-2 API; yes if local child/switch are public.
- Difficulty: moderate.
- Risk: medium. Over-constraining existing supervisor would reject useful same-domain error payloads.
- Probe shape: positive portable supervisor state with atomic failure cell; negative current `failures : list ref` captured by portable child completion.
- Open questions: does cross-domain supervisor need ordered failure history or just a concurrent bag?

### I-14 — Resource cache updates only after successful loads and keeps last-good on refresh failure

- Statement: `Resource.t` owns a loader, last successful value, and refresh failure history. `refresh` updates cache only after `load` succeeds; auto refresh catches typed failures, preserves last-good, records `Cause.Fail err`, and calls `on_error`.
- Source location: `packages/effet/resource.ml:1-47`; survival rationale `journal.md:7195-7351`.
- Current enforcement: mutable field plus ref, Eio/runtime daemon protocol. Same-domain only; domain safety is explicitly not promised.
- Candidate OxCaml feature(s): Portable.Atomic for value/failures; Capsule for isolated mutable state; immutable_data constraints on payloads; contention.
- Public API annotations: depends. Current generic `Resource.t` should not silently gain payload constraints; add `Resource.Portable` or a constrained constructor.
- Difficulty: moderate.
- Risk: low if separate API; medium if widening current API.
- Probe shape: existing positives `resource_portable_atomic_positive.ml:1-24`, `resource_portable_auto_parallel_positive.ml:1-42`, `effet_resource_portable_probe.ml:4-73`; negatives `resource_ref_portable_negative.ml:1-12`, `resource_stdlib_atomic_portable_negative.ml:1-21`.
- Open questions: should `Portable.Atomic` be used directly or hidden behind Resource state? Is failure history ordered under domain updates?

### I-15 — `Schedule.t`/`Duration.t` are pure schedule descriptions except jitter randomness

- Statement: Duration is an int-millisecond value with nonnegative clamps; Schedule is a pure AST describing recurrence policy. `Jittered` uses global `Random.float` during interpretation, so the value is pure but interpreter output is not deterministic.
- Source location: `packages/effet/duration.ml:1-28`; `packages/effet/schedule.ml:1-73`.
- Current enforcement: value types; runtime checks for clamping and divide-by-zero option. No mode annotations.
- Candidate OxCaml feature(s): portable/immutable_data kind on `Duration.t` and non-jitter schedule values; explicit RNG capability for portable deterministic scheduling.
- Public API annotations: probably no unless making a portable schedule module.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive portable `Duration.t` and non-jitter `Schedule.t`; negative uses `Jittered` inside domain-parallel deterministic evaluator with global `Random` if rejected/undesirable.
- Open questions: is `Random.float` portable-safe under OxCaml, or should `Jittered` move to runtime-owned RNG?

### I-16 — Trace context is validated W3C data and should remain pure/portable

- Statement: `Trace_context.t` contains hex trace/span IDs, flags, tracestate, and baggage. Constructors reject malformed or all-zero IDs; inject/extract operate on header lists without dependencies.
- Source location: `packages/effet/capabilities.mli:44-61`; `packages/effet/trace_context.ml:1-113`.
- Current enforcement: runtime validation in `make`/`extract`; pure records/lists.
- Candidate OxCaml feature(s): portable kind, immutable_data.
- Public API annotations: no or trivial kind annotation if global migration uses modes.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive portable `trace_context` sent through parallel task; negative malformed traceparent still returns `None` dynamically.
- Open questions: baggage metadata/percent-decoding may add richer payloads; keep them immutable strings.

### I-17 — In-memory tracer state is mutable, fiber-local, and runtime-local

- Statement: `Tracer.in_memory` tracks open spans, pending attrs/links, and finished spans in mutable state keyed by Eio fiber context; it is suitable for same-domain tests/runtimes, not cross-domain shared tracing.
- Source location: `packages/effet/tracer.ml:34-88,100-217`.
- Current enforcement: Eio fiber-local state and mutable records; no locks. Fallback state handles use outside runtime fiber context.
- Candidate OxCaml feature(s): locality for tracer state, Capsule for mutable collector, Atomic/Mutex for a portable collector variant.
- Public API annotations: no for current tracer; portable exporter adapter may need a new type.
- Difficulty: speculative.
- Risk: medium. Tracing is runtime-local by design; forcing portability into `Tracer.in_memory` may overbuild tests.
- Probe shape: negative capture `Tracer.in_memory` in a portable span callback; positive build `Tracer.Portable.in_memory` with atomic/capsule state if needed.
- Open questions: should portable runtime emit trace events to a concurrent queue, or return them as part of execution result?

### I-18 — In-memory logger/meter buffers are same-domain collectors

- Statement: Logger and Meter in-memory adapters append records/points to mutable lists and dump in order. They are runtime-local collectors, not shared concurrent sinks.
- Source location: `packages/effet/logger.ml:18-32`; `packages/effet/meter.ml:18-35`; capability payloads `packages/effet/capabilities.mli:72-136`.
- Current enforcement: mutable list fields; no synchronization. Payload records are pure strings/ints/floats/lists.
- Candidate OxCaml feature(s): portable payload kind; Atomic/capsule collector variant for cross-domain runtime.
- Public API annotations: payload maybe yes; current in-memory collector no.
- Difficulty: moderate.
- Risk: low.
- Probe shape: positive send `log_record`/`point` through parallel boundary; negative capture current `in_memory` mutable collector in portable callback.
- Open questions: do metric values need unboxed representations for perf, or is this premature?

### I-19 — Span metadata nodes carry only propagation-safe data

- Statement: `Named`, `Annotate`, `Link_span`, `With_external_parent`, and `With_context` store span kind, strings, string attrs, and trace context. These should be portable data even if the tracer implementation is not.
- Source location: `packages/effet/effect.ml:45-56,157-183`; `packages/effet/capabilities.mli:38-70`.
- Current enforcement: typed records, dynamic validation for `with_external_parent` via `Trace_context.make`.
- Candidate OxCaml feature(s): portable kind/immutable_data on span metadata records.
- Public API annotations: no unless portable AST constructors expose kind requirements.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive portable AST containing only metadata nodes; negative `link_attrs` cannot contain non-string payload because type already blocks it.
- Open questions: none beyond full AST kind inference.

### I-20 — `Log` and `Metric_update` payloads are lazy runtime-scoped signals

- Statement: logs and metrics are AST nodes interpreted by the runtime so they are lazy, sequenced with effects, correlated with active span, and runtime-local rather than process-global.
- Source location: constructors `packages/effet/effect.ml:57-68`; builders `effect.ml:185-190`; runtime interpretation `packages/effet/runtime.ml:508-528`; V-LM decision `journal.md:6864-7044`.
- Current enforcement: effect AST sequencing; payload types are pure. Logger/meter implementations may be mutable/nonportable.
- Candidate OxCaml feature(s): portable payload kinds; portable logger/meter capabilities for domain runtime.
- Public API annotations: depends on portable runtime.
- Difficulty: moderate.
- Risk: low. V-LM explicitly kept these nodes as Effet-native signals.
- Probe shape: positive portable AST with `Log`/`Metric_update`; negative payload not possible today except through nonportable logger/meter capture.
- Open questions: should a portable runtime require `logger : logger @ portable`, or collect signals structurally and export on parent domain?

### I-21 — `run`, `run_exn`, and `drain` are same-domain interpreter entry points today

- Statement: `Runtime.run` interprets an effect to an `Exit.t` under a fresh switch/finalizer stack. `run_exn` re-raises defects with captured backtrace. `drain` busy-yields until runtime-owned daemons complete. None of these promises cross-domain execution.
- Source location: `packages/effet/runtime.mli:17-33`; `packages/effet/runtime.ml:873-905`.
- Current enforcement: Eio runtime only; shipped program runs under OxCaml as same-domain smoke but is rejected across `Parallel_scheduler`.
- Candidate OxCaml feature(s): sibling `run_parallel`/`create_pool` for portable effects; locality for runtime handles.
- Public API annotations: yes on new entry point; no on existing.
- Difficulty: moderate.
- Risk: medium. Changing existing `run` semantics would surprise users.
- Probe shape: positive `Runtime.run_parallel` executing portable AST on two domains; negative existing `Runtime.run` result containing nonportable env cannot cross domains.
- Open questions: how are Eio services represented in a domain-parallel runtime?

### I-22 — Stream AST callbacks must match the same-domain or portable stream runtime

- Statement: stream transformations store functions and effects (`Map`, `Map_effect`, `Filter`, `Scan`, `Flat_map`, `Flat_map_par`, sinks). These callbacks can capture mutable state today and are interpreted by Eio fibers.
- Source location: `packages/effet-stream/effet_stream.ml:44-81,120-160,203-280`.
- Current enforcement: ordinary OCaml functions; `flat_map_par` validates positive max dynamically. No mode enforcement.
- Candidate OxCaml feature(s): portable callback annotations for domain stream runtime; kind annotation on stream AST.
- Public API annotations: depends; same-domain stream remains unannotated, portable stream likely separate.
- Difficulty: moderate.
- Risk: medium. Stream is pull/fold-oriented and Eio-heavy; domain streams may need a separate sink protocol.
- Probe shape: positive stream map/filter/fold over immutable data under `Parallel_scheduler`; negative mapper captures `ref`.
- Open questions: should `flat_map_par` domain version preserve output interleaving, ordering, or only set semantics?

### I-23 — Stream concurrent transport is Eio-queue backed and nonportable across domains

- Statement: `from_eio_stream`, `from_file`, `merge`, and `flat_map_par` use `Eio.Stream`, `Eio.Promise`, `Eio.Switch`, `Atomic` stop flags, and supervisor children. This is correct for Eio fibers and type-visible as nonportable under domain parallelism.
- Source location: `packages/effet-stream/effet_stream.ml:281-376,382-593`; V-Sh decisions `journal.md:7044-7195`.
- Current enforcement: Eio runtime/backpressure; bounded queues avoid deadlocks by protocol. Existing OxCaml negative rejects `Eio.Stream.add` inside parallel domains.
- Candidate OxCaml feature(s): portable sink with `Portable.Atomic`, contention, separate domain-safe queue design.
- Public API annotations: yes for a portable stream sink; no for Eio stream interop.
- Difficulty: moderate.
- Risk: medium.
- Probe shape: existing positive `stream_portable_sink_parallel_positive.ml:1-38`; negative `stream_eio_queue_parallel_negative.ml:1-17`. Extend to `merge`-like two emitters and failure collection.
- Open questions: can Effet reuse a portable queue library, or should domain stream composition avoid queues and use reducers?

### I-24 — Stream file errors preserve original `exn`; portable diagnostics need a separate shape

- Statement: `from_file` maps Eio I/O exceptions into typed `file_error` with operation/path/kind/message and original `cause : exn`. Same-domain consumers get diagnostics; cross-domain consumers should not assume `exn` is portable.
- Source location: API `packages/effet-stream/effet_stream.mli:16-26,74-100`; implementation `packages/effet-stream/effet_stream.ml:169-185,293-334`.
- Current enforcement: typed failure variant plus runtime mapping; `exn` is trusted same-domain payload.
- Candidate OxCaml feature(s): portable diagnostic record without `exn`, or two error modes.
- Public API annotations: depends. Current API exposes `exn`, so a portable stream package likely needs `portable_file_error`.
- Difficulty: moderate.
- Risk: medium. Dropping `exn` globally weakens debugging.
- Probe shape: positive portable file-error mirror with only strings/kind; negative current `file_error` under portable kind if `exn` rejected.
- Open questions: can `exn` be rendered at boundary and preserved as string plus backtrace?

### I-25 — PPX-generated leaves must not hide env capture or duplicate capability bindings

- Statement: `ppx_effet` enforces explicit capability lists, rejects direct `env` identifier usage in leaf bodies, rejects duplicate capability bindings, and expands to `Effect.fn`/`Effect.thunk` plus env object builders. Generated code currently has no mode annotations.
- Source location: parser/checker `packages/ppx_effet/ppx_effet.ml:25-105`; env builder `ppx_effet.ml:107-131`; registrations `ppx_effet.ml:133-155`; decision `journal.md:6320-6640`.
- Current enforcement: compile-time PPX checks for shape/duplicates/env creep; no portability checks.
- Candidate OxCaml feature(s): generated `@@ portable` leaves for portable profile; mode-aware sub-PPX interaction; kind annotations on generated env object if needed.
- Public API annotations: depends on new syntax/profile, e.g. `[%effet.portable_thunk ...]`.
- Difficulty: moderate.
- Risk: low if additive. High if PPX starts inferring services/modes; that was explicitly rejected.
- Probe shape: positive PPX expansion includes portable thunk accepted with immutable captures; negative body captures `ref` or uses `env` directly.
- Open questions: can a ppx safely emit mode syntax while remaining compatible with mainline OCaml builds?

### I-26 — OTel exporter mutable tables and queues are runtime-local, not domain-portable

- Statement: `effet-otel` exporter owns Eio queues for spans/logs/metrics, mutable span table/handles, RNG, callbacks, and daemon loops. It is an Eio runtime adapter, not a domain-portable data structure.
- Source location: state `packages/effet-otel/effet_otel.ml:391-411`; loops `effet_otel.ml:436-488`; construction/forked daemons `effet_otel.ml:604-658`.
- Current enforcement: Eio switch lifetime and runtime-local usage; no locks around `Hashtbl`/`Random.State`/mutable spans.
- Candidate OxCaml feature(s): locality for exporter handle; Capsule or mutex if making cross-domain exporter; portable queue abstraction.
- Public API annotations: probably no; document exporter as same-domain Eio adapter.
- Difficulty: speculative.
- Risk: medium.
- Probe shape: negative capture `Effet_otel.t` in portable callback; positive encode-only payload in portable domain then enqueue/export on parent domain.
- Open questions: should domain runtime export signals through a parent-domain collector rather than making exporter itself portable?

### I-27 — OTel callbacks and encoders should separate portable payload encoding from Eio export

- Statement: encoders are pure over span/log/metric payloads; export loops and `on_error`/`on_send` callbacks are effectful mutable runtime operations. `in_flight` atomic tracks flushing.
- Source location: span/log/metric encoders `packages/effet-otel/effet_otel.ml:49-174,196-356`; post/inflight `effet_otel.ml:421-434`; logger/meter adapters and flush `effet_otel.ml:675-710`.
- Current enforcement: callbacks caught and ignored on send/error; atomic counter; no mode split.
- Candidate OxCaml feature(s): portable pure encoder functions; `on_error`/`on_send` callbacks local/nonportable; atomic kind for `in_flight`.
- Public API annotations: no unless adding portable encoder module signatures.
- Difficulty: moderate.
- Risk: low.
- Probe shape: positive call `Internal.encode_*` from parallel domain with immutable payloads; negative call `logger t` or `meter t` from domain captures Eio queue.
- Open questions: are mutable fields in `Internal.span` acceptable for portable encoding, or should encoder input be immutable exported span records?

### I-28 — Schema values are pure; effectful policies are the only env-row boundary

- Statement: `Schema.t` is a pure codec/equality record. Decode/encode failures become typed Effet failures; `decode_with_policy` is where env-row requirements enter. This avoids weak env variables and keeps schema reusable.
- Source location: API `packages/effet-schema/effet_schema.mli:89-235`; implementation `packages/effet-schema/effet_schema.ml:220-689`; decisions `journal.md:3666-3966` and cleanup `journal.md:8915-9075`.
- Current enforcement: public abstract schema type; effectful policy typed by ordinary env row; no mode annotations. Equality/encode/decode callbacks may capture arbitrary same-domain state.
- Candidate OxCaml feature(s): portable kind on a portable schema type; `@@ portable` for decode/encode/equal callbacks; immutable_data for issue/json.
- Public API annotations: depends. A portable schema package may constrain callbacks; current package should remain general.
- Difficulty: moderate.
- Risk: low if pure schema principle remains.
- Probe shape: positive portable schema over primitive/record/tagged union with portable callbacks; negative schema transform/refine captures `ref`.
- Open questions: should `equal` callbacks be required portable in portable schemas? Are recursive lazy schemas compatible with portable kind inference?

### I-29 — Schema adapters isolate external JSON modes from core schema values

- Statement: `JSON_ADAPTER` keeps dependency-specific JSON outside core schemas; adapters convert external values at decode/encode boundary and return Effet failures.
- Source location: `packages/effet-schema/effet_schema.mli:238-262`; `packages/effet-schema/effet_schema.ml:692-717`.
- Current enforcement: module signature; external_json unconstrained.
- Candidate OxCaml feature(s): portability boundary around external_json, kind annotation on adapter functor only if exported portable adapters exist.
- Public API annotations: depends per adapter.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive adapter for portable JSON representation; negative adapter external_json containing closure cannot be used in portable decode.
- Open questions: should adapter functor expose both same-domain and portable decode variants?

### I-30 — Capabilities env channel is object-row requirements, not provide/layer state

- Statement: Effet's environment is a structural object row; helpers require methods such as `clock`, but Effet deliberately avoids Effect-TS `provide`/Layer machinery. Applications own service construction and state.
- Source location: `packages/effet/capabilities.mli:1-23,25-140`; row/layer decisions around `journal.md:5245-5493` and PPX/capability decisions around `journal.md:6320-6640`.
- Current enforcement: OCaml row polymorphism; no runtime provide. Object methods can carry arbitrary values/objects and may be nonportable.
- Candidate OxCaml feature(s): object mode annotations, portable capability object profiles, local capabilities for Eio resources.
- Public API annotations: speculative. Annotating object rows publicly may be invasive.
- Difficulty: speculative.
- Risk: high. Forcing modes into every env row could fight Effet's central DX advantage.
- Probe shape: positive portable env object with immutable/portable methods; negative env object carrying Eio clock/net or mutable service crossing domain. Keep ordinary env rows unannotated.
- Open questions: can OxCaml express “this method is portable” ergonomically on structural object rows? Does a portable runtime use env objects at all or explicit arguments?

### I-31 — Samplers are closure records; portable runtimes need portable sampler callbacks

- Statement: `Sampler.t` stores one function. Runtime calls it before opening spans. A sampler may capture arbitrary state today.
- Source location: `packages/effet/sampler.ml:1-30`; runtime calls at `packages/effet/runtime.ml:429-432,553-556`.
- Current enforcement: typed function record only.
- Candidate OxCaml feature(s): `sample : ... -> bool @ portable` in portable sampler; immutable_data for attrs.
- Public API annotations: yes only on portable sampler type.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive portable ratio/always_on sampler; negative custom sampler captures `ref`.
- Open questions: should hash-based `ratio` be deterministic across domains/toolchains?

### I-32 — `Private.view` relies on representation identity and abstract-constructor discipline

- Statement: `Private.view` is `%identity` from abstract `t` to a constructor-exposed alias. This depends on `view` and `t` having bit-identical constructors and package code not forging mismatched representations.
- Source location: `packages/effet/effect.ml:248-328`.
- Current enforcement: module abstraction and comment; no runtime check. It is an intentional layout invariant for performance.
- Candidate OxCaml feature(s): layout annotations, unboxed/mixed block investigation, kind annotations must preserve representation; maybe nothing else.
- Public API annotations: no.
- Difficulty: speculative.
- Risk: medium. Representation tinkering can easily fight simplicity.
- Probe shape: positive compile/run microbench showing `%identity` works under annotated portable AST; negative impossible in typed code unless abstraction is broken.
- Open questions: can unboxed/mixed blocks improve AST allocation without making public representation fragile?

### I-33 — Heterogeneous `par`/`race` casts are slot-local and must stay hidden

- Statement: runtime uses `Obj.repr`/`Obj.obj` to store heterogeneous `par` results and race winner values. The invariant is slot locality: unpack occurs only at the slot/winner produced by that same typed child.
- Source location: `packages/effet/runtime.ml:326-344` for `Par`; `runtime.ml:705-756` for `Race`.
- Current enforcement: runtime protocol and existential comments; no static proof beyond local code shape.
- Candidate OxCaml feature(s): unique/capsule for slot tokens, layout/existential package refactor, maybe no direct mode feature.
- Public API annotations: no.
- Difficulty: speculative.
- Risk: medium.
- Probe shape: positive typed slot package without `Obj` in a portable runtime prototype; negative attempts to read slot at wrong type should be unrepresentable.
- Open questions: is removing `Obj` worth possible allocation/perf cost, especially after OxCaml perf wins?

### I-34 — Error renderers are scoped captures used only at interpretation/observability time

- Statement: `Render_error` and `named ?error_renderer` store `err -> string` callbacks to convert typed failures into span statuses/exception messages inside the scoped effect.
- Source location: `packages/effet/effect.ml:44,144,157-164`; runtime rendering `packages/effet/runtime.ml:129-163,412-413`.
- Current enforcement: typed function; capture safety trusted.
- Candidate OxCaml feature(s): portable callback on portable AST; local callback on same-domain AST.
- Public API annotations: depends.
- Difficulty: trivial.
- Risk: low.
- Probe shape: positive portable renderer over polymorphic variant; negative renderer captures `ref` or object with nonportable state.
- Open questions: should portable runtime render errors on worker domain or return causes to parent for rendering?

### I-35 — Public precondition checks remain dynamic unless promoted to typed APIs

- Statement: small API preconditions are runtime checks: bounded parallelism max > 0, valid external trace IDs, stream max/chunk size > 0, nonempty race/cause aggregation. They are not Effet semantic invariants worth heavy type machinery unless repeated bugs justify it.
- Source location: `packages/effet/effect.ml:126-128,175-178`; `packages/effet-stream/effet_stream.ml:99-109`; `packages/effet/cause.ml:24-33`; `packages/effet/runtime.ml:715-744`.
- Current enforcement: `invalid_arg`, `failwith`, or conversion to `Cause.Die`.
- Candidate OxCaml feature(s): something else; type-level naturals or nonempty lists are possible but likely over-engineered.
- Public API annotations: no.
- Difficulty: trivial.
- Risk: low.
- Probe shape: retain runtime negative tests; no OxCaml-specific fixture unless a `Nonzero_int.t` helper is introduced.
- Open questions: should `race []` be typed as an immediate `Die` instead of `failwith`, independent of OxCaml?

### I-36 — Delay, timeout, retry, repeat use runtime-owned clocks and scheduler step refs

- Statement: time is not stored as an Eio value in the AST. `Delay`, `Timeout`, `Repeat`, and `Retry` carry pure `Duration.t`/`Schedule.t`, but interpretation uses `runtime.sleep`, mutable step/result refs, and `Schedule.next_delay`; `Jittered` calls global `Random.float`.
- Source location: runtime clock setup at `packages/effet/runtime.ml:105-113`; delay/timeout at `runtime.ml:308-315`; repeat/retry loops at `runtime.ml:814-871`; schedule randomness at `packages/effet/schedule.ml:41-73`.
- Current enforcement: Eio runtime and ordinary refs; schedule data is typed, but jitter determinism/domain-safety is implicitly trusted.
- Candidate OxCaml feature(s): locality for runtime clock/sleep handles, portable kind for duration/schedule data, explicit portable RNG or runtime-owned RNG for jitter.
- Public API annotations: no for existing same-domain runtime; depends for a portable runtime that evaluates schedules on worker domains.
- Difficulty: moderate.
- Risk: medium. Moving `Jittered` randomness out of `Schedule.next_delay` would be cleaner for portability but changes a small public behavior.
- Probe shape: positive portable evaluator for non-jitter schedules; negative portable evaluator for `Jittered` if global `Random.float` or captured RNG is rejected. Add a separate positive with an explicit portable RNG token if needed.
- Open questions: should `Schedule.jittered` remain a pure AST node whose randomness is supplied by runtime, or keep today's direct `Random.float` implementation?

### I-37 — Cancellation maps to `Interrupt`; `Uninterruptible` protects only Eio cancellation windows

- Statement: Effet translates `Eio.Cancel.Cancelled _` and `Exit` into `Cause.Interrupt`, while `Uninterruptible` maps to `Eio.Cancel.protect`. It does not turn cancellation into a typed failure and it does not mask defects.
- Source location: public docs at `packages/effet/effect.mli:104-110`; exception mapping at `packages/effet/runtime.ml:66-67,291,305,868`; protected finalizers at `runtime.ml:225-226`; uninterruptible node at `runtime.ml:377-379`; supervisor cancellation at `runtime.ml:648-656`.
- Current enforcement: Eio runtime cancellation semantics; dynamic exception matching.
- Candidate OxCaml feature(s): locality for cancellation contexts and switches; something else for cancellation algebra because modes do not model cancellation delivery.
- Public API annotations: no.
- Difficulty: moderate.
- Risk: low. This is central Eio behavior; OxCaml should not rewrite it unless a domain runtime has a separate cancellation token.
- Probe shape: positive same-domain fixture showing cancellation remains `Interrupt`; negative domain-runtime fixture attempting to capture Eio cancel context in a portable callback.
- Open questions: what is the portable-runtime equivalent of `Eio.Cancel.sub` and `Switch.fail`?

### I-38 — Ordered result collection is an interpreter invariant, not guaranteed by raw parallelism

- Statement: `All`, `All_settled`, and `for_each_par` return results in input order even though child fibers complete out of order; `Race` returns first success and aggregates failures only if all fail. Stream `merge` intentionally does not preserve order, while `flat_map_par` preserves bounded concurrency but interleaves outputs.
- Source location: `packages/effet/runtime.ml:310-378,675-784`; stream merge/flat_map_par at `packages/effet-stream/effet_stream.ml:382-593`.
- Current enforcement: arrays indexed by input position, Eio queues for race/stream, and interpreter protocol. Domain ordering is not statically expressed.
- Candidate OxCaml feature(s): portable reducers, immutable result arrays/slices, contention-safe output slots, unique slot tokens.
- Public API annotations: yes only for a domain-parallel runtime or portable stream API.
- Difficulty: moderate.
- Risk: medium. Raw `Parallel.fork_join` is not a drop-in replacement; Effet's observable ordering has to be preserved deliberately.
- Probe shape: positive portable `all` reducer over indexed inputs that returns input order; negative unordered shared list/ref accumulator rejected or proven wrong by fixture.
- Open questions: should domain `for_each_par` preserve input order like fiber `for_each_par`, or should a separate unordered API exist?

### I-39 — Schema JSON/issue values are portable data, but numeric and source identity checks stay dynamic

- Statement: `effet-schema` owns a pure JSON representation and structured issue records. It dynamically validates JSON number literals, finite floats, exact ints, missing fields, schema names, and adapter-originated issues; these are data-contract checks, not mode checks.
- Source location: JSON and issue types at `packages/effet-schema/effet_schema.ml:1-218`; schema implementation at `effet_schema.ml:220-689`; cleanup decisions at `journal.md:8915-9075`; adapter/source identity at `journal.md:9010-9075`.
- Current enforcement: runtime validation returning `issue list`; pure data types; schema callbacks can still capture arbitrary state.
- Candidate OxCaml feature(s): immutable_data/portable kind for `Json.t`, `issue`, `issue_kind`, `path_segment`; portable callback profile for portable schemas.
- Public API annotations: depends. Data types can be annotated in a portable build, but current `Schema.t` should not silently constrain all callbacks.
- Difficulty: trivial for data, moderate for callback-bearing `Schema.t`; table difficulty records the data invariant.
- Risk: low.
- Probe shape: positive portable JSON/issue values crossing `Parallel_scheduler`; negative portable schema `refine` callback capturing `ref` under a portable-schema profile.
- Open questions: do `Float.nan`/non-finite rejection and `Intlit` exactness need refined types, or are dynamic issue records sufficient?

### I-40 — Capability object adapters may hide Eio resources behind pure-looking methods

- Statement: env rows and capability class types are structurally simple, but methods can close over Eio clocks, network handles, mutable collectors, or application state. A portable env object must constrain the method implementations, not just the visible row type.
- Source location: capability class types and `clock_of_eio` at `packages/effet/capabilities.ml:1-96`; runtime accepts tracer/logger/meter/env at `packages/effet/runtime.mli:3-15`; env-row docs at `packages/effet/effect.mli:7-15`.
- Current enforcement: OCaml object row typing only; no provide/layer runtime and no mode guarantee for object methods.
- Candidate OxCaml feature(s): object modes, portable object profiles, local capability values for Eio-backed resources.
- Public API annotations: speculative. Annotating all env rows would be invasive; portable runtime may instead accept explicit portable capabilities.
- Difficulty: moderate.
- Risk: high. Over-constraining env rows would fight Effet's “applications own state; Effet owns interpretation” boundary.
- Probe shape: positive portable env object with immutable methods; negative env object whose method captures `Eio.Stdenv.clock`, `Eio.Net.t`, or `ref` and is sent to a portable runtime.
- Open questions: can OxCaml express method-level portability ergonomically for structural object rows?

### I-41 — OTel metric aggregation is batch-local mutable state and must not become shared state accidentally

- Statement: `aggregate_points` uses a local `Hashtbl` to combine metric points by normalized key inside one batch. That mutable table is safe because it is scoped to encoding, not exporter state shared across fibers/domains.
- Source location: metric key/aggregation/encoding at `packages/effet-otel/effet_otel.ml:196-356`; public test/bench exposure at `packages/effet-otel/effet_otel.mli:50-61`.
- Current enforcement: lexical scope and ordinary mutable table; no locks needed because the table is not shared.
- Candidate OxCaml feature(s): keep encoder input/output portable and table local; no Capsule unless aggregation is parallelized.
- Public API annotations: no unless exposing a portable encoder signature.
- Difficulty: moderate.
- Risk: low.
- Probe shape: positive call `aggregate_points`/`encode_metrics_request` in a portable worker with immutable points; negative stash the local table in exporter state or share it across worker callbacks.
- Open questions: should `Effet.Meter.point` be annotated portable before `Internal.encode_metrics_request` is advertised as worker-safe?

### I-42 — `Trace_context.make` and stream/file builders encode boundary validation dynamically

- Statement: boundary constructors reject malformed inputs at runtime: W3C IDs must be lowercase hex/nonzero; stream `flat_map_par` max and file chunk size must be positive; file errors classify Eio exceptions dynamically. These are input-validation contracts, not static ownership contracts.
- Source location: trace validation at `packages/effet/trace_context.ml:14-113`; stream checks at `packages/effet-stream/effet_stream.ml:99-109`; file error mapping at `effet_stream.ml:169-185`.
- Current enforcement: `option`, `invalid_arg`, and typed file errors.
- Candidate OxCaml feature(s): refined value types or private smart constructors, but mostly “something else”; modes do not replace parsing and validation.
- Public API annotations: no.
- Difficulty: trivial.
- Risk: low.
- Probe shape: keep ordinary negative tests for malformed traceparent/chunk size; no OxCaml fixture unless creating portable refined ID wrappers.
- Open questions: should trace IDs/span IDs become private types before migration, or would that add ceremony without improving mode safety?

### I-43 — Tests and internal clocks rely on same-domain mutable fixtures, not library portability claims

- Statement: the test clock, sleeper list, and many test-side refs intentionally use same-domain mutation to deterministically drive Eio fibers. These are verification scaffolds, not public Effet contracts, and should not be mistaken for portable-runtime requirements.
- Source location: `packages/effet/test/test_effet.ml:63-90,98-126`; stream runtime helper at `packages/effet-stream/test/test_effet_stream.ml:15-27`.
- Current enforcement: test-only module scope and Eio single-domain runtime.
- Candidate OxCaml feature(s): none for public API; locality for test helpers if tests are compiled in an OxCaml mode profile.
- Public API annotations: no.
- Difficulty: trivial.
- Risk: low.
- Probe shape: do not port test fixtures to `Portable.Atomic` unless they start testing a portable public API; add separate portable fixtures under `scratch/oxcaml_research/fixtures/` instead.
- Open questions: should future portable-runtime tests use deterministic portable schedulers rather than adapting the Eio test clock?

## Recommended migration order

1. Preserve same-domain Effet as the baseline.
   - Blocks: all user-facing changes. Keep `Effect.t`, `Runtime.run`, `Resource.t`, `Supervisor.scoped`, and stream operators source-compatible while adding mode-aware siblings.
   - Verification: shipped OxCaml compatibility remains green (`effet`/`effet-stream`/`effet-otel`/`effet-schema`/`ppx_effet`).

2. Add small pure/payload kind annotations first.
   - Invariants: I-11, I-15, I-16, I-19, I-31, I-39, I-42, parts of I-20 and I-28.
   - Rationale: these are low-risk immutable data surfaces and reveal syntax/tooling friction without changing runtime ownership.
   - Probe dependencies: portable `Cause` mirror, trace_context, log/metric payloads, sampler positives/negatives.

3. Land `once` release probe and API shape.
   - Invariants: I-03, I-08.
   - Rationale: high value, low conceptual risk, existing fixtures already prove the core mechanism.
   - Blocks: finalizer stack redesign and portable resource cleanup.

4. Build portable Resource as a separate module or experimental namespace.
   - Invariants: I-14, I-12, I-18 if metrics/resource failures are exported.
   - Rationale: existing probes are strong; do not widen generic `Resource.t` silently.
   - Blocks: domain runtime examples that need shared cached state.

5. Decide `local_` strategy for switches/supervisors.
   - Invariants: I-04, I-05, I-13.
   - Rationale: `local_` is real, but Eio public annotations and real supervisor ergonomics are unresolved. Keep rank-2 until a real probe beats it.
   - Blocks: replacing supervisor API; does not block portable AST work.

6. Split or annotate the Effect AST.
   - Invariants: I-01, I-02, I-06, I-20, I-31, I-34, I-36, I-37, I-38.
   - Rationale: this is the central migration and the highest recursive-GADT risk. It should happen after small payload and callback probes clarify syntax.
   - Blocks: `Runtime.run_parallel`.

7. Prototype a portable runtime sibling.
   - Invariants: I-06, I-09, I-10, I-12, I-21, I-33, I-36, I-37, I-38.
   - Rationale: keep Eio `Runtime.run` boring; add `Runtime.run_parallel` only for portable AST values. Expect explicit context passing instead of Eio fiber-local keys.

8. Revisit stream and OTel domain stories last.
   - Invariants: I-22, I-23, I-24, I-26, I-27, I-41.
   - Rationale: current designs are deliberately Eio/queue/exporter based. Portable stream sinks and pure encoders are likely quick wins, but full domain stream/export protocols need real workloads.

9. Keep Capabilities/env rows conservative.
   - Invariants: I-30, I-40.
   - Rationale: object-row env is one of Effet's core simplifications. Avoid public mode noise until a portable env fixture proves good ergonomics.

## Open questions for dossier/external research

- OxCaml recursive GADT practicality: can the full `Effect.t` view carry kind annotations without unacceptable `with` threading, or is a portable AST split mandatory?
- Eio mode roadmap: will `Eio.Switch.t`, `Eio.Stream.t`, `Eio.Promise.t`, and fiber keys gain locality/portability annotations upstream, or should Effet wrap them?
- Portable exception diagnostics: what is the recommended OxCaml representation for `exn` and `Printexc.raw_backtrace` at domain boundaries?
- Object-row modes: can structural object rows express portable capabilities ergonomically, or should portable runtime entry points avoid object envs?
- Atomic choice: why Stdlib `Atomic.t` is rejected in the existing portable Resource probe while `Portable.Atomic` works; what are the exact kind constraints and performance implications?
- Capsule API fit: is Capsule a better public story for Resource/tracer/exporter mutable state, or is it too heavyweight compared with `Portable.Atomic`?
- Once semantics on continuations: can `Bind`/`Map` continuations be modeled as once per interpretation without making reusable AST values linear?
- Portable queues: is there an OxCaml/Jane Street queue/deferred primitive that can replace Eio.Stream for domain stream operators, or should Effet use reducer-style parallelism?
- PPX portability: how to emit OxCaml mode syntax from `ppx_effet` while keeping mainline-compatible builds or conditional syntax paths.
- Layout/perf: after V-OxCaml-Perf, which allocation/layout optimizations matter for `Effect.t` without undermining the current `%identity` view invariant?
- Scheduler/RNG boundary: should `Schedule.jittered` continue using global `Random.float`, or should all portable scheduling receive explicit runtime RNG state?
- Ordered domain collection: can OxCaml/Jane Street parallel APIs provide an ergonomic ordered reducer, or should Effet build one for `all`/`for_each_par`?
