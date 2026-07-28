# DX-E39 Phase 0 — Source audit

Evidence ID family: `V-DX-E39-*` (this file is the branch source census).
Sealed predictions live in `.scratch/research/dx/e39/journal.md` and were not
edited here.

**Method.** Exhaustive `rg` over tracked/worktree source under `lib/`, `test/`,
`bench/`, `docs/` (excluding fenced `docs/research/`), `drivers/`,
`http-testsuite/`, `tools/`, and allowed `.scratch/research/**`, with
`_build*`, `_opam/`, `.reference/`, and the objective scope fence excluded:

- `.scratch/research/dx-journal.md`
- `docs/research/`
- `.scratch/research/dx-prd-0001.md`
- `.scratch/research/orchestrator-state.md`

Primary symbols: `Effect.audit`, `Effect.describe`, `Effect.collect_names`,
`assert_no_*`, `assert_pure_eff`, `capability_footprint`, `union_footprint`,
`Custom.names`, `leaf_name`, `named`, `with_names`. Definitions are separated
from consumers. Classification uses the objective’s four buckets and the
external-consumer model (V-DX-PRINC-1): in-repo unusedness is not proof of
unnecessity; a structural need must still be named.

**STOP condition (objective §scope fence / names↔tracing).** Checked
mechanically below. **Not triggered:** runtime tracing does **not** read the
propagated `Custom.names : string list` field. Tracing opens spans from the
`named`/`fn` evaluator’s explicit `~name` argument via
`Runtime_instrument.with_span`. See §2.

---

## 1. Consumer map

### 1.0 Definitions (not consumers)

| Symbol | Kind | Location |
| --- | --- | --- |
| `type audit` | public type | `lib/eta/effect.mli:25-33` (docs `34-47`); impl `lib/eta/effect_core.ml:66-74` |
| `val audit` | public API | `lib/eta/effect.mli:1229-1247`; impl `lib/eta/effect_core.ml:678-688` |
| `val describe` | public API | `lib/eta/effect.mli:1249-1257`; impl `lib/eta/effect_core.ml:690-713` |
| `val collect_names` | public API | `lib/eta/effect.mli:1220-1227`; impl `lib/eta/effect_core.ml:676` (`let collect_names eff = names eff`) |
| `val name` | public API (leaf only) | `lib/eta/effect.mli:1219`; impl `lib/eta/effect_core.ml:675` (`leaf_name`) |
| `assert_no_clock` … `assert_pure_eff` | public `eta_test` API | `lib/test/eta_test.mli:228-262`; impl `lib/test/eta_test.ml:751-781` |
| `fail_audit` | private helper | `lib/test/eta_test.ml:751-753` (uses `Effect.describe` for failure text) |

**Public assertion count discrepancy.** Objective text repeatedly says “the
four assertions” / “all four `eta_test` assertions.” The **public** surface
exports **seven** values:

1. `assert_no_clock` — `lib/test/eta_test.mli:228`
2. `assert_no_logs` — `:234`
3. `assert_no_metrics` — `:238`
4. `assert_no_concurrency` — `:242`
5. `assert_no_resources` — `:246`
6. `assert_no_background` — `:251`
7. `assert_pure_eff` — `:256`

E12’s own report also counted seven (`.scratch/research/dx/e12/report.md`).
The EOP audit §6.1 lists the same seven. Treat “four” in `objective.md` as
**inaccurate relative to the public MLI**, not as a hidden second surface.
Endpoint S/R migration must delete **all seven**, not four.

---

### 1.1 `Effect.audit`

| # | File:line | Role | Classification | Notes |
| --- | ---: | --- | --- | --- |
| A0 | `lib/eta/effect.mli:25-47`, `:1229-1247`; `lib/eta/effect_core.ml:66-74`, `:678-688` | definition | *(def)* | Public contract + implementation. |
| A1 | `lib/test/eta_test.ml:756,759,762,765,769,773,777` | internal implementation of all seven assertions | **self-test infrastructure** (library helper, not an app) | Sole non-test-suite library caller of `Effect.audit`. |
| A2 | `test/core_common/effect_common_suites.ml:204` (`check_audit`), `:233-292` (`test_audit_declared_leaves_and_preserve_union`), `:294-305` (`test_audit_does_not_force_bind_continuation`), `:310-326` (`test_expert_audit_declarations_and_inheritance`), `:375-393` (`test_audit_generated_false_flags_match_runtime`), `:2946-2966` (`test_par3_par4_audit_aggregates_children`); registered `:3954-3961`, `:4186` | suite self-tests of audit algebra | **self-test** | Dominant in-repo use. Local helper `audit` at `:220-231` builds expected `Effect.audit` records (not a call). |
| A3 | `test/effect_introspection/redteam_effect_audit.ml:15-16` (contract at `:21-27`) | honesty/red-team probe | **self-test** | Proves bind under-report and `preserve` union; gate executable. |
| A4 | `test/blocking_common/blocking_common_suites.ml:68-72` (`test_blocking_run_declares_background_footprint`); registered `:329` | package boundary: `Eta_blocking.run` must declare background/concurrency/resources | **boundary check** | The objective’s named `blocking_common` consumer. Not application logic — cross-package footprint contract. |
| A5 | `lib/eta/syntax.mli:33-35` | documents that `and*` right side is invisible to audit | **doc ref** | Normative cross-ref on sequential product. |
| A6 | `lib/test/eta_test.mli:231`, `:257` | assertion docs point at `{!Eta.Effect.audit}` | **doc ref** | |
| A7 | research prose (E12 report/journal/redteam, EOP §6.1, e39 journal, objectives, LAWS.md R93) | historical / law registry | **doc ref** (research) | Not runtime. Law row R93 registers audit tests at `.scratch/research/dx/e22/review/LAWS.md`. |

**Real (application / production runtime) consumers of `Effect.audit`:**
**none found** under `lib/` (except `eta_test` helpers), `drivers/`,
`bench/`, `tools/`, `http-testsuite/`.

**External-consumer reading.** Absence of in-repo app call sites is **not**
by itself a kill argument. No structural production need was identified in
source either: every live call is test, boundary, or docs. The only
cross-package boundary is A4 (`eta_blocking` footprint declaration check).

---

### 1.2 `Effect.describe`

| # | File:line | Role | Classification | Notes |
| --- | ---: | --- | --- | --- |
| D0 | `lib/eta/effect.mli:1249-1257`; `lib/eta/effect_core.ml:690-713` | definition | *(def)* | Renders `Pure`/`Fail`/`Custom`/`Map`/`Bind`; Bind adds literal `<bind …>`; does **not** read `names` or `footprint` fields (only `leaf_name` on Custom). |
| D1 | `test/effect_introspection/snapshot_effect_describe.ml:4` (corpus `:6-26`) | deterministic snapshot printer | **self-test** + **structural teaching tool** | Objective gates byte-identical output master↔S. |
| D2 | `test/core_common/effect_common_suites.ml:305` | bind description string check inside audit bind test | **self-test** | |
| D3 | `test/core_common/effect_common_suites.ml:385` | failure message when generated blueprint reaches poisoned clock | **self-test** | |
| D4 | `lib/test/eta_test.ml:753` | `fail_audit` pretty-prints blueprint via `describe` | **self-test infrastructure** | Couples assertions to `describe` for human failure text only. |
| D5 | `lib/eta/syntax.mli:33-35` | same `and*` introspection caveat | **doc ref** | |
| D6 | research (E12, EOP, e39, LAWS debt CD-E22-014) | design history | **doc ref** | |
| D7 | `bench/effect_construction/construction_sink.ml:9` at pre-deletion commit `ba1275f4` | anti-elision fingerprint for the E39 construction benchmark | **self-test / benchmark infrastructure** | Missed by the original Phase-0 table despite the stated `bench/` search. It is not application/runtime demand for `describe`. S′ restores the same call for cross-tree benchmark comparability. |

**Real production/runtime consumers:** **none found.**

**Structural need (named, not frequency):** the snapshot executable and the
public “blueprint is a value / printable” teaching contract. That is the
Endpoint-S keep rationale for `describe`, independent of `audit`.

---

### 1.3 `Effect.collect_names`

| # | File:line | Role | Classification | Notes |
| --- | ---: | --- | --- | --- |
| C0 | `lib/eta/effect.mli:1220-1227`; `lib/eta/effect_core.ml:142-146`, `:676` | definition | *(def)* | Walks only `Custom.names` / Map/Bind inner; no continuations. |
| C1 | `test/core_common/effect_common_suites.ml:187-201`; registered `:3953` | pre-order name list | **self-test** | |
| C2 | `test/runtime_common/runtime_common_suites.ml:135-147`; registered `:1178` | duplicate/near-duplicate of C1 on runtime suite facade | **self-test** | |
| C3 | `test/api_dx/api_dx_examples.ml:1142-1143` (`blueprint_names_proposed`); snippet corpus `:1652-1654`; scanner `:2877` | DX guide example / surface scan expects one `Effect.collect_names` mention | **self-test** (doc-example harness) | Not production. |
| C4 | `docs/api-dx.md:165-166`, `:699-705`, `:846` | promoted diagnostic/preflight surface | **doc ref** (public docs) | Claims preflight/documentation use; hedges “not a runtime inventory.” |
| C5 | `lib/eta/syntax.mli:33-35` | `and*` caveat | **doc ref** | |
| C6 | LAWS.md R93 / CD-E22-014 | law registry | **doc ref** | |
| C7 | internal producers feeding the field (not `collect_names` callers) | `named`, `preserve`, concurrent combinators, `concat`, Expert | *(producer)* | See §2. |

**Real production/runtime consumers:** **none found.**

**Structural need:** public docs promote `name`/`collect_names` as the
diagnostic/preflight row (`docs/api-dx.md:846`). That is a claimed external
teaching/preflight need, still with zero in-repo application call sites.

---

### 1.4 `Eta_test` assertions (`assert_no_*` / `assert_pure_eff`)

| # | File:line | Symbol(s) | Classification | Notes |
| --- | ---: | --- | --- | --- |
| S0 | `lib/test/eta_test.mli:228-262`; `lib/test/eta_test.ml:755-781` | all seven | *(def)* | Each calls `Effect.audit`; failures call `describe`. |
| S1 | `test/test/test_eta_test.ml:1109-1121` (`test_audit_assertions_accept_matching_blueprints`); registered `:1222` | `assert_pure_eff`, `assert_no_clock`, `assert_no_logs`, `assert_no_metrics`, `assert_no_concurrency`, `assert_no_resources`, `assert_no_background` (×2) | **self-test** | **Only** executable consumer of the assertion API in the whole tree. Positive-path only (matching blueprints accepted); no negative fail-path tests found. |
| S2 | — | — | **boundary check** | **None.** The blocking boundary (A4) calls `Effect.audit` directly, not `assert_*`. |
| S3 | `lib/test/eta_test.mli` docs; research E12/EOP | hedges on static spine | **doc ref** | |
| S4 | `test/api_dx/api_dx_examples.ml:2546` `assert_no_explicit_bind` | **not in scope** | Name collision only; unrelated to audit assertions. |

**Real application behavior checks:** **none found.**

---

### 1.5 Consumer map summary (against sealed predictions)

| Surface | Self-test | Boundary | Doc ref | Real | Prediction (journal) |
| --- | --- | --- | --- | --- | --- |
| `audit` | dominant (A2,A3) + eta_test impl (A1) | A4 blocking footprint | A5–A7 | **0** | match |
| `describe` | D1–D4, D7 | 0 | D5–D6 | **0** (T5 printability rationale; no observed application demand) | partial — tooling existed, but the original teaching/demand interpretation was too strong |
| `collect_names` | C1–C3 | 0 | C4–C6 | **0** (docs claim preflight) | match |
| assertions | S1 only | **0** (not blocking) | S3 | **0** | boundary prediction slightly high — boundary uses raw `audit` |

---

## 2. Dependency map — footprints, names, tracing

### 2.1 Representation

`Custom` node (`lib/eta/effect_core.ml:121-128`):

```ocaml
| Custom :
    {
      eval : frame -> ('a, 'err) Exit.t;
      leaf_name : string option;
      names : string list;
      footprint : capability_footprint;
    }
    -> ('a, 'err) t
```

`capability_footprint` (`:76-83`) mirrors the six audit booleans (no `names`).

Interpreter (`:180-184`) **discards** metadata:

```ocaml
| Custom { eval; _ } -> eval frame
```

So neither `names` nor `footprint` participates in evaluation control flow.

### 2.2 Footprint — producers and readers

**Producers / threaders** (non-exhaustive mechanism list; all construction-time):

| Mechanism | Location | Behavior |
| --- | --- | --- |
| `footprint` / `no_footprint` / `concurrency_footprint` | `effect_core.ml:85-106` | constructors |
| `union_footprint` | `effect_core.ml:108-116` | boolean OR |
| `make ~footprint` | `effect_core.ml:159-160` | stores on Custom |
| `preserve` | `effect_core.ml:162-165` | unions child footprint + extra |
| `capability_footprint` walk | `effect_core.ml:152-157` | Pure/Fail empty; Custom field; Map/Bind inner only |
| `concat_footprints` | `effect_core.ml:168-171` | list fold |
| `Expert.make` | `effect.ml:66-88` | required `capabilities` list → footprint; optional `inherit_` union |
| Library leaves | `effect_core.ml` (sleep/now/never/async/…), `effect_concurrent.ml`, `effect_observability.ml`, `effect_resource.ml`, `effect_schedule.ml`, `effect_supervisor_scope.ml`, `channel.ml`, `queue.ml`, `pubsub.ml`, `promise.ml`, `pool.ml`, `semaphore.ml`, `effect.ml` (daemon, metric_timer) | declare flags at leaf construction |
| `eta_blocking` | `lib/blocking/eta_blocking.ml:36-37`, `:119-120`, `:151-153` | Expert declarations including `` `Background `` |

**Readers of footprint data:**

| Reader | Location | Purpose |
| --- | --- | --- |
| `capability_footprint` | as above | construction-time union input |
| `audit` | `effect_core.ml:678-688` | **sole public semantic reader** of the six flags |
| assertion helpers | `eta_test.ml:755-781` | via `audit` |
| tests listed in §1 | various | via `audit` |

No runtime module (`runtime*.ml`, `tracer.ml`, `runtime_instrument.ml`)
references `capability_footprint` or `.footprint`.

### 2.3 Names — producers and readers

**Field / helpers:**

| Symbol | Location | Role |
| --- | --- | --- |
| `Custom.names` | `effect_core.ml:125` | stored list |
| `names` walk | `effect_core.ml:142-146` | Pure/Fail `[]`; Custom field; Map/Bind **inner only** |
| `concat_names` | `effect_core.ml:167` | `List.concat_map names` |
| `make ?names` | `effect_core.ml:159-160` | default `[]` |
| `preserve` | `effect_core.ml:163` | copies `names eff` onto wrapper |
| `with_names` | `effect_core.ml:194-198` | **defined, zero callers** outside `effect_core.ml` |
| `collect_names` | `effect_core.ml:676` | public alias of `names` |
| `audit.names` | `effect_core.ml:681` | public copy of `names eff` |
| `leaf_name` / `name` | `effect_core.ml:148-150`, `:675` | **separate** optional single label for describe/`Effect.name` |

**Producers of aggregated `names`:**

| Site | Location | What is stored |
| --- | --- | --- |
| `Effect.named` | `effect_observability.ml:70-71` | `name :: names eff` **and** `leaf_name:name` |
| `Effect.fn` | via `named` (`effect_observability.ml:428`) | same |
| `race` / `par` / `par3` / `par4` / `all` / `all_settled` | `effect_concurrent.ml:214-375` | child `names` concatenation |
| `concat` | `effect_core.ml:398-401` | child names |
| `with_background` | `effect_supervisor_scope.ml:270` | `names background` |
| `Expert.make ?names` | `effect.ml:80-88` | optional author list (`eta_blocking` passes `~names:[name]`) |
| `preserve` wrappers | many | inherit inner names |

**Contrast — `map_par` does not aggregate child names**
(`effect_concurrent.ml:380-388`): only `~leaf_name:"Effect.map_par"` and
concurrency footprint; mapper is unforced at construction. This is the dual of
`all`’s special case (§2.5).

**Readers of `names` / `collect_names` / `audit.names`:**

| Reader | Reads | Runtime tracing? |
| --- | --- | --- |
| `names` / `collect_names` / `audit` | yes | no |
| tests/docs in §1 | via public API | no |
| `eval` | **no** (`Custom { eval; _ }`) | n/a |
| `describe` | **no** (uses `leaf_name` option only) | n/a |
| `Runtime_instrument.with_span` | **no** — receives `~name` string argument | span naming is the arg |
| `runtime_*.ml` / `tracer.ml` | **no matches** for effect `names` field | — |

### 2.4 Tracing vs static `names` — mechanical verdict

`named` implementation (`lib/eta/effect_observability.ml:70-85`):

```ocaml
let named ?(kind = Capabilities.Internal) ?error_pp name eff =
  make ~leaf_name:name ~names:(name :: names eff)
    ~footprint:
      (union_footprint (capability_footprint eff)
         (footprint ~uses_clock:true ())) @@ fun frame ->
  ...
    (Runtime_instrument.with_span ~runtime:frame.runtime
       ...
       ~name ~attrs:[] (fun () -> run_to_value frame eff))
```

- **Tracing path:** closure argument `name` → `Runtime_instrument.with_span ~name`.
- **Static introspection path:** `~names:(name :: names eff)` and
  `~leaf_name:name` stored on the node for `collect_names` / `audit` /
  `describe` (`leaf_name` only).
- These share a construction site but **not** a read path: the evaluator never
  loads `custom.names`.

**Objective stop condition (“if runtime tracing reads propagated `names`”):
NOT MET.** Endpoint work may treat aggregated `names` as introspection-only.
`named` / `leaf_name` / the span evaluator must remain for tracing and for
`describe`’s `Custom("…")` labels. This matches the sealed journal prediction.

### 2.5 `all`’s special introspection behavior

**EOP claim** (`.scratch/research/eop-audit-2026-07-26.md` §6.1 architectural
cost list): *“`all` ma specjalne zachowanie związane z introspekcją”*
(`all` has special behavior related to introspection).

**Public contract** (`lib/eta/effect.mli:234-250`), quote:

> Unlike {!map_par}, whose mapper is not forced while constructing the
> blueprint, [all] receives prebuilt effects and aggregates their static names
> and capability footprints for introspection.

**Implementation** (`lib/eta/effect_concurrent.ml:370-378`):

```ocaml
let all ?(max_concurrent = 8) effects =
  if max_concurrent <= 0 then
    invalid_arg "Effect.all: max_concurrent must be > 0";
  let inputs = Array.of_list effects in
  let n = Array.length inputs in
  make ~leaf_name:"Effect.all" ~names:(concat_names effects)
    ~footprint:(concurrent_footprint effects) @@ fun frame ->
  collect_workers frame ~name:"Effect.all" ~workers:(min max_concurrent n)
    ~inputs ~f:Fun.id ~n
```

**What is “special”:**

1. **Construction-time aggregation** of every list element’s `names` and
   footprints into the outer `Custom` (`concat_names` +
   `concurrent_footprint` = child union OR concurrency).
2. **Contrast with `map_par`** (`:380-388`), which shares `collect_workers`
   runtime shape but stores **empty** names (default) and only a bare
   concurrency footprint — children do not exist as values at blueprint build.
3. Same aggregation pattern also appears on `race`, `par`/`par3`/`par4`,
   `all_settled` (prebuilt children). The **documented** special call-out pairs
   `all` specifically against `map_par` because they are the dynamic-list twins
   with divergent introspection.

**Not special:** admission/`max_concurrent` liveness (EOP §4.7) is runtime
scheduling, orthogonal to introspection metadata.

**Self-test locking the behavior:**
`test/core_common/effect_common_suites.ml:248-268` — `"all preserves child
metadata"` expects five named children’ flags and names on one `Effect.all`.

**Endpoint S implication:** deleting footprints/`names` aggregation removes
this special case; `all` becomes construction-symmetric with `map_par` on the
metadata axis (runtime admission unchanged). Snapshot `describe` for `"all"`
still shows `Custom("Effect.all")` via `leaf_name` only.

---

## 3. Honesty audit — public MLI / docs claims

Scope: **public** contracts in `lib/eta/*.mli`, `lib/test/eta_test.mli`, and
non-fenced `docs/**/*.md`. Research ledgers under fenced `docs/research/` were
not used as honesty sources. Hedges emphasized.

### 3.1 `type audit` — `lib/eta/effect.mli:25-47`

```text
type audit = {
  names : string list;
  uses_clock : bool;
  emits_logs : bool;
  emits_metrics : bool;
  has_concurrency : bool;
  has_resources : bool;
  has_background : bool;
}
(** Static preflight summary of an effect blueprint.

    The summary covers only the blueprint's currently constructed static spine
    and capability footprints declared by Eta library leaves. It is not a
    runtime inventory. In particular, {!bind} and other continuation-producing
    combinators do not call ordinary OCaml continuation functions during
    inspection, so an effect constructed later by such a function is absent.

    Every [true] capability flag means that the static blueprint may use that
    capability if execution reaches the declaring leaf. It may over-report one
    execution because control flow or disabled observability can prevent the
    operation. A [false] flag excludes only declared use in the visible static
    blueprint; it does not constrain opaque continuation code, arbitrary work
    inside {!sync}, or a dishonest custom {!Expert.make} declaration. *)
```

**Hedges:** static spine only; not runtime inventory; bind continuations
unforced; `true` = possibility / may over-report; `false` ≠ proof of absence
(sync, opaque continuations, dishonest Expert).

### 3.2 `val audit` — `lib/eta/effect.mli:1229-1247`

```text
val audit : ('a, 'err) t -> audit
(** Inspect the statically constructed part of an effect blueprint.

    [names] has the same ordering and continuation boundary as
    {!collect_names}. [uses_clock] is set by declared Eta clock reads or sleeps,
    including clock-backed scheduling and observability timestamps.
    [emits_logs] and [emits_metrics] are set by declared log and metric leaves.
    [has_concurrency] is set by declared fiber/concurrent combinators.
    [has_resources] is set by declared resource scopes or finalizer lifecycle
    combinators. [has_background] is set only by declared runtime-owned work
    that may outlive the caller's lexical scope; structured background work sets
    [has_concurrency] but not [has_background].

    Flags are unioned across the visible static spine and through Eta wrappers.
    They are conservative possibilities, so [true] does not promise an observed
    operation. Conversely, [false] says only that no visible declared leaf has
    that footprint. For example, the sleep in
    [bind (fun () -> sleep duration) unit] is invisible because inspecting the
    blueprint never calls the continuation. *)
```

**Hedges:** “statically constructed part”; “declared”; “conservative
possibilities”; explicit bind-sleep counterexample for under-report.

### 3.3 `val collect_names` — `lib/eta/effect.mli:1220-1227`

```text
val collect_names : ('a, 'err) t -> string list
(** [collect_names eff] returns names that are statically present in
    [eff]'s current description.

    This is a preflight/documentation helper, not a complete runtime inventory.
    Continuation-producing nodes such as [bind], [bind_error], [map_par], and
    [supervisor_scoped] are not forced or traversed,
    so names created by those continuations are intentionally absent. *)
```

**Hedges:** preflight/documentation only; not complete runtime inventory;
listed continuation nodes unforced. (`val name` at `:1219` has **no** dedicated
doc comment.)

### 3.4 `val describe` — `lib/eta/effect.mli:1249-1257`

```text
val describe : ('a, 'err) t -> string
(** Render the statically constructed blueprint as a deterministic tree without
    evaluating it.

    The node labels are [Pure], [Fail], [Custom], [Custom("name")], [Map], and
    [Bind], with two spaces per child depth and no trailing newline. A [Bind]
    includes its visible input subtree followed by a literal [<bind …>] child;
    the continuation is never forced. Opaque custom/wrapper evaluators remain
    leaves rather than pretending their runtime work is inspectable. *)
```

**Hedges:** static only; no evaluation; bind continuation never forced; opaque
customs stay leaves. (Honest relative to implementation: describe does not
claim capability flags.)

### 3.5 `Expert.make` capability paragraph — `lib/eta/effect.mli:838-861`

```text
val make :
  ?leaf_name:string ->
  ?names:string list ->
  ?inherit_:('child, 'child_err) t ->
  capabilities:
    [ `Clock | `Logs | `Metrics | `Concurrency | `Resources | `Background ]
    list ->
  (context -> ('a, 'err) Exit.t) ->
  ('a, 'err) t
(** Build a runtime-backed effect without exposing Eta's internal effect
    representation. ...

    The capability declaration is required because the evaluator is an opaque
    function that {!audit} cannot inspect. Include [`Clock], [`Logs],
    [`Metrics], [`Concurrency], [`Resources], or [`Background] when the custom
    leaf directly performs the corresponding operation. An omitted capability
    is a contract made by the custom leaf author, not something Eta can verify.
    [`Background] also sets [has_concurrency], so a background declaration
    cannot produce an internally inconsistent audit.
    Pass a statically available child as [inherit_] when the evaluator wraps it;
    its declared footprint is unioned with the custom leaf's direct footprint.
    Effects created later by ordinary functions remain opaque. *)
```

**Hedges:** declaration required **because audit cannot inspect** eval;
omission is author contract, **unverifiable**; later-built effects opaque.
This is the honesty hinge the dishonesty probe must exercise on master.

### 3.6 `all` introspection sentence — `lib/eta/effect.mli:247-249`

Quoted in §2.5. Claims aggregation of static names and capability footprints;
pairs against `map_par`. No hedge beyond the general static model.

### 3.7 `Syntax.(and*)` — `lib/eta/syntax.mli:29-35`

```text
(2) The right effect sits inside a bind continuation, so
static introspection ({!Effect.collect_names}, {!Effect.audit},
{!Effect.describe}) sees only the left side; use {!Effect.par} when both
sides should appear.
```

**Hedge:** sequential product hides the right side from all three APIs.

### 3.8 `Eta_test` assertions — `lib/test/eta_test.mli:228-262`

Each `assert_no_*` repeats the static-spine / opaque-continuation boundary.
Composite:

```text
val assert_pure_eff : ('a, 'err) Eta.Effect.t -> unit
(** Fail when any capability flag in {!Eta.Effect.audit} is true.

    Here “pure” means no declared Eta capability footprint in the visible static
    blueprint. It does not establish referential transparency for arbitrary
    functions passed to {!Eta.Effect.sync}, and it cannot inspect effects created
    later by opaque continuations. Names alone do not make an effect impure. *)
```

**Hedges:** “pure” redefined as no **declared** footprint; not referential
transparency; sync unchecked; continuations unchecked; names ≠ impurity.
Naming remains the strongest remaining footgun (sounds like a guarantee).

### 3.9 Public docs (`docs/api-dx.md`) — collect_names / name only

`docs/api-dx.md:165-166`:

> `Effect.name` and `Effect.collect_names` for preflight documentation of
> statically present blueprint names. This is not a runtime inventory.

`:699-705`:

> `Effect.name` and `Effect.collect_names` are not replaced by a parallel manual
> registry of expected workflow names. They inspect the existing effect
> description before interpretation and are useful for documentation, preflight
> checks, and diagnostics. They are intentionally not a complete runtime
> inventory: names created by continuation-producing nodes such as `bind`,
> `bind_error`, `map_par`, or supervisor bodies are not forced just to
> inspect them.

`:846` table row:

> | Diagnostic/preflight surface | `name`, `collect_names` |

**Not present in non-research public docs:** `Effect.audit`, the six flags, or
any `assert_no_*` / `assert_pure_eff`. Audit honesty lives entirely in the MLI
(+ `eta_test.mli`). That is itself evidence: docs already demoted audit out of
the preferred DX guide while keeping `collect_names`.

### 3.10 Honesty summary

| Claim family | Over-report admitted? | Under-report admitted? | Sounds stronger than hedges? |
| --- | --- | --- | --- |
| `type audit` / `val audit` | yes (`true` may over-report) | yes (bind, sync, Expert lie) | moderate — “preflight summary” |
| `collect_names` / docs | n/a | yes (continuations) | low — explicitly preflight |
| `describe` | n/a | yes (opaque leaves, bind) | low — tree of static nodes |
| `assert_pure_eff` | inherits audit | inherits audit | **high** — identifier “pure” |
| `Expert.make` capabilities | n/a | author can omit | honest that Eta cannot verify |

The API’s own prose already concedes the EOP §6.1 charge; the residual risk is
**named assurances** (`assert_pure_eff`, “pure”) and the representation cost of
a hedged quasi-effect-row, not silent false certainty in the MLI text.

---

## 4. Exhaustiveness checklist

Searches performed (fenced paths excluded):

1. `Effect.audit` / `type audit` across `lib` `test` `docs` `bench` `drivers`
   `tools` `http-testsuite` allowed `.scratch`
2. `Effect.describe`
3. `collect_names`
4. `assert_no_clock|logs|metrics|concurrency|resources|background` and
   `assert_pure_eff`
5. `capability_footprint|union_footprint|footprint:` in `lib/` `test/`
6. `names` / `with_names` / `leaf_name` in `lib/eta`
7. `names` in `lib/eta/runtime*.ml`, `tracer.ml`, `runtime_instrument.ml` →
   **empty**
8. Production `lib/` minus `lib/test` and effect internals → **empty** for
   audit/describe/collect_names/assert
9. Cross-check: `map_par` vs `all` construction; `eval` pattern-match; `named`
   span path

**Intentionally not searched as consumers:** package “audit catalogs”
(`lib/*/audit/run.sh` dependency-escape audits) — unrelated homonym.

**Blocked / skipped:**

- Did not read fenced orchestrator/PRD/dx-journal/docs-research paths.
- Did not inspect `_build*` or `.reference/`.
- Cost baseline microbenchmark is **out of scope for this file** (Phase 0
  sibling artifact per objective); not produced here.
- No commit made (per task instruction).

**Surprises / contradictions to flag for the parent agent:**

1. **Objective “four assertions” vs seven public vals** — migration text must
   mean the full `assert_no_*` + `assert_pure_eff` set (seven), or the
   objective is under-specified.
2. **Boundary check does not use assertions** — only raw `Effect.audit` in
   `blocking_common`. Deleting assertions alone would not touch that test;
   deleting `audit` would.
3. **`with_names` is dead** inside core (define-only).
4. **`describe` is footprint-free and almost names-free** (uses `leaf_name`
   only) — Endpoint S keep is footprint-free by construction, as objective
   hoped.
5. **STOP condition clear:** tracing ≠ static `names` field.
6. Public DX docs already omit `audit` while retaining `collect_names` —
   soft prior for S over keeping audit.

---

## 5. Endpoint-relevant freeze points (source only)

| Keep candidates (S) | Delete candidates (S) | Further delete (R) |
| --- | --- | --- |
| `describe`, `collect_names`, `name`/`leaf_name`, `named` span evaluator | `type audit`, `val audit`, footprint field + unions + Expert capabilities requirement, seven assertions, `all`/peers’ footprint aggregation special-casing | public `describe` + `collect_names` (internal `names` optional drop if still unused by tracing — confirmed droppable for tracing) |

Law-registry touch points when deleting: R93 audit rows and any
`effect.mli:1213-1247` spans in `.scratch/research/dx/e22/review/LAWS.md`
(not edited in this Phase-0 file).
