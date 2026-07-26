VERDICT: KEEP ETA ENVLESS

Repository evaluated: https://github.com/ribelo/eta @ e3f3907f (master, 2026-07-26).
Independent compiler verification: OCaml 5.2.0 (the repo's stated minimum; the
project's own toolchain pins OxCaml 5.2.0minus-31 via flake.nix). All
experiments cited below as (LAB x) were compiled and run in a clean lab;
repository-internal labs are cited by their in-repo paths.

---

## 1. Executive justification

Eta should keep `('a, 'err) Eta.t` with ordinary OCaml dependency passing.
Four independent lines of evidence converge, and at least two of them are
individually decisive.

**(a) The framing that R was "removed by a prose mistake" is factually
wrong.** The task brief relies on journal V-R8–V-R10, which reversed the
prose-based removal (V-R5–V-R7) and called the intervening prose "noise".
But the env parameter that actually shipped after V-R10 was removed months
later by a *different, newer compiler-lab-driven* decision: V-Recovery-R2,
V-Recovery-Envless-Core, and V-Recovery-B0 (all 2026-05-22, implemented in
commit 7417b03b). The driver was the project's adopted OxCaml direction:
V-Recovery-R2's fixtures showed closed object environments fail the portable
boundary ("object kind was value mod global many non_float, not value mod
portable contended"), and the envless-core fixture showed the portable core
needs only `('err, 'a)` plus ordinary arguments. The shipped code still
carries the scar: `lib/eta/capabilities.mli` documents `random` as "a
portable token, **not an object capability**, because object-method
capabilities are nonportable across OxCaml domain boundaries", and the
flake pins `oxcaml 5.2.0minus-31` with CI jobs for mode syntax and OxCaml
shipped tests. Restoring an object-row R makes every effect value
non-portable and either kills the islands/portable direction — Eta's most
distinctive engineering bet — or forces exactly the two-primary-effect-types
split this evaluation forbids. A "portable R" is not an escape: R2 tested
the portable-compatible env shapes (closed records, phantom tuples), and
closed records have no row polymorphism — which is the entire inference
dividend of R. A portable R therefore has no advantage over arguments.

**(b) The repository's own later labs had already hollowed out every
support of R before the removal.** After V-R10 "won", each pillar was
retested and fell:

- `Effect.provide`: deleted as unearned. Three with/without fixture pairs
  (scoped factory, mock injection, sandbox) behaved identically, and the
  without-provide versions were shorter (−1/−11/−7 LOC) with better errors
  (.scratch/research/evidence/provide_survival, V-RPv5). I re-verified the
  equivalence (LAB e8).
- `Layer`: the restricted `merge_explicit` compiles but "is not materially
  better than ordinary OCaml"; the faithful version recreates
  Tag/Context/presence-set machinery with ordering and duplicate hazards
  (V-RLv5; .scratch/research/evidence/layer_research/README.md).
- DX at scale (20 modules, 30 capabilities): env-row missing-capability
  errors are 2295 bytes/40 lines vs 689 bytes/15 lines for args; reusable
  env-row values need thunks; hovers are dense rows
  (.scratch/research/evidence/r_dx_research/results/summary.md).
- The final in-repo R position (V-RFv5) had already retreated to "env rows
  for leaf/runtime-boundary capabilities only; ordinary arguments for
  service graphs". The capabilities that remained in the row — clock, log,
  metrics, tracer, random — are precisely what the current design owns as
  runtime services (`Effect.with_clock`, `with_logger`, `with_tracer`,
  scoped, fiber-local, per zio-boundaries.md). The narrowed R and the
  envless design differ only by a global type parameter that no longer
  pays for itself.

**(c) The value restriction is a structural OCaml cost, not a style
issue.** My lab confirms and sharpens the repo's thunk finding. Any
constructor that reads the environment (`Sync : ('r -> 'a) -> ...`, or the
ZIO-style `Ask : ('r, 'r, 'err) t`) forces `'r` to be non-covariant. The
compiler says so directly: "expected parameter ... to be covariant, but it
is injective contravariant" (callback encoding) and "injective invariant"
(Ask encoding) (LAB e10_vr, e10b_ask). Because the relaxed value
restriction only generalizes covariant positions, **every reusable
top-level effect value with an open-row requirement — and even a pure
`let program = pure 42` in a library whose GADT reads env — gets weak type
variables**. Eta-expansion is mandatory, not optional. This compounds
fatally with Layer: layer *values* with open rows cannot even be exported
from a compilation unit ("contains the non-generalizable type variable(s)")
(LAB e12_inf), so the entire Layer algebra becomes thunk-passing — and
thunking destroys value identity, which destroys memoisation-by-reference,
which forces explicit nominal keys back into the "key-free" design.

**(d) Cross-library composability fails structurally, and the fix
recreates ordinary OCaml DI.** Object-row keys are global structural
names. Two libraries choosing `db` vs `database` for the same `Db.t`
silently force the application to bind both keys to one handle (LAB e15);
same-shape different-meaning collisions compile undetected (repo
`hazard_same_shape_collision.ml`). The proposed remedy — projection
functors (`module type DEPS = sig type env val db : env -> Db.t end`) —
compiles, but the inferred requirement collapses from a minimal structural
row to the single opaque `D.env` (LAB e15, S16), which is exactly
"ordinary OCaml functor-based DI with an additional Reader layer" the task
asks me to check for. Meanwhile the one genuine, compiler-verified win of
R — deep-leaf dependency changes touch 1 file instead of ~4 (repo
`library_evolution.ml`; LAB e6) — is real but bounded, and is absorbable
in the envless style with composite capability records at subsystem
boundaries.

The decision criteria that matter most here — OCaml-native integration,
Layer viability, public type quality, and architectural permanence — all
point the same way. Eta keeps its current architecture.

---

## 2. Strongest argument for the rejected architecture (RESTORE R)

The case for R is real, compiler-verified, and was under-weighted by the
prose that removed it the first time. Stated at full strength:

In a large application with deep call graphs, ordinary argument passing
makes every intermediate function a manual dependency-forwarding layer.
When a leaf five levels down gains a requirement (a metrics sink, a
feature-flag client), every function on the path must be edited — not
because its own logic changed, but because OCaml gives no other channel.
The repo's `library_evolution.ml` measured this: env-row touched 1 file,
args touched 4, and I reproduced the same ratio (LAB e6). Over years of
application evolution this is a steady tax of pure plumbing edits, each a
churn- and review-cost with zero semantic content, and each an opportunity
for a stale intermediate signature to silently pin an old service.

With the object-row R, the compiler maintains a complete, always-current
dependency inventory of the whole program for free. My lab confirms the
mechanics end-to-end (LAB e1_core): a five-level chain whose intermediate
bodies mention no services infers
`(< db : db; audit : audit; log : log; cache : cache; .. >, int, 'err) t`;
a branching graph with a shared dependency unifies correctly through `par`;
omitting a service at boot fails statically with "The second object type
has no method cache" (LAB e7_boot). The brief's "discoveries" 1–2 are
correct and I verified them: requirement-free effects stay polymorphic in
`'r` and compose cleanly (parametricity is the correct analogue of
Effect-TS `never`; `unit` provably does not unify with an object row, LAB
e1_neg_unit), and transitive requirements in a parent's type are a
*truthful* summary, not false pollution. Two same-typed services with
different roles (`primary_db` / `analytics_db`) are distinguishable by
name — something type-indexed DI does not give you (LAB e15, S14).

If Eta were an application-framework for single-team codebases on stock
OCaml, with no OxCaml portability ambition, this package would be
defensible — arguably superior — despite the thunk tax and noisy errors.
That is the honest steelman. It loses in *this* repository because the
repository has already staked its architecture on the OxCaml portable
boundary that object rows cannot cross, and because every supporting
pillar (provide, Layer, black-box substitution, reusable values) was
retested in-repo and found unearned.

---

## 3. Findings from the repository

### 3.1 What the removal commit actually was

Commit `7417b03b544b599a767aaedcf181254287c96776` ("feat: remove effet env
parameter", 2026-05-22) migrated the full tree — core, stream, schema,
otel, ppx — from `('env, 'err, 'a) Effect.t` to `('a, 'err) Effect.t`,
removed `Runtime.create ~env`, deleted `[%effet.env]`, and converted
`Effect.thunk` to zero-argument leaves with explicit captures. Its journal
entry is **V-Recovery-B0** ("Envless core Effet", "Status: accepted and
implemented"), which states: "This supersedes earlier env-row journal
decisions for shipped core Effet." Its evidence base is the OxCaml
recovery campaign (V-Recovery-R1/R2/R3, V-Recovery-Envless-Core), not the
V-R5–V-R7 prose that V-R9 discredited. **Any evaluation that treats the
current envless state as the residue of a debunked prose argument is
working from an incomplete record.** The R2 fixture directory named in the
journal (`.scratch/research/evidence/oxcaml_research/recovery/`) is no
longer in the tree (only `portable_islands/decision.md` survives), so the
OxCaml fixtures cannot be re-run from git; however, the journal records
exact compiler diagnostics, and the constraint is independently
corroborated by shipped code (`capabilities.mli` portable token; the
`eta_par`/`eta_blocking` island APIs taking explicit portable inputs and
callbacks) and by OxCaml's documented treatment of objects under modes.

### 3.2 Audit of previous conclusions

| Journal decision | Verdict now |
|---|---|
| V-R1–V-R4 (keep object-row env; add provide; no Layer) | Inference claims correct; provide claim wrong (later deleted by the project's own lab). |
| V-R5–V-R7 (drop env on Eio precedent) | Right destination, weak method (pure prose). V-R9's rejection of its *reasoning* was fair; its conclusion was later re-arrived at empirically. |
| V-R8–V-R10 (compiler lab: R-B wins auto-DI; "no code change required") | Technically correct and independently re-verified (LAB e1–e7). But the lab's success criterion was scoped to auto-DI only. It never tested portability, value restriction at scale, cross-library keys, or Layer economics. "The prose entries between V-R1 and V-R8 were noise" was overconfident: the lab answered a narrower question than the architecture needs. |
| V-RPv5 (delete provide; args do everything) | Correct; strongest method in the series (three with/without pairs, identical behavior). Re-verified (LAB e8). |
| V-RLv5 (no Layer; restricted merge compiles but isn't better) | Correct. My E12 adds two costs the entry missed: layer values hit the value restriction and cannot cross module boundaries; thunking breaks memoisation-by-identity. |
| V-Dxv1–v6 (R at 20 modules: build time fine, errors noisy, thunks needed; keep R with mitigations) | Measurements correct. But the mitigation list — thunk everything reusable, keep examples away from big rows, use args for app graphs — was quietly conceding the design center to arguments. |
| V-RFv5 (narrowed R: rows for leaf/boundary capabilities only) | The honest end-state of R: a leaf-capability channel. Its remaining contents (clock/log/metrics/tracer) are now runtime-owned interpreter services with scoped `with_*` overrides. |
| V-Recovery-R2 / Envless-Core / B0 (objects non-portable; portable core envless; remove env from shipped core) | Correct and decisive. This — not V-R5 — is the operative rationale for the current architecture. |
| V-DX-E16-001 (Reader race; predicted kill) | Prediction only; branch `research/dx-e16-reader-race` contains zero commits beyond the seal. See §3.4. |

### 3.3 The current envless model is coherent, not a leftover

`docs/services.md` ("Services Without Layer") and `docs/zio-boundaries.md`
describe a complete, shipped idiom: module-owned handle types, constructor
functions returning `Eta.t`, `with_resource` / `with_scope` +
`acquire_release` for lifetimes, runtime-owned services with scoped
fiber-local overrides (`with_clock`, `with_logger`, `with_tracer`,
`intercept_log`), and explicit portable inputs at island boundaries.
`examples/service_composition.ml` shows the pattern working with typed
errors and resource safety. This is not an absence of an answer; it is the
answer the R research converged on after every R component was survival-
tested.

### 3.4 On the E16 Reader race (V-DX-E16-001)

The brief is correct that E16 is only a sealed prediction, and correct
that as designed it cannot be decisive: one service and a shallow scenario
cannot surface the deep-chain/transitive-substitution properties where R's
value concentrates. Two further problems: (1) it races a *Reader wrapper*
(`'env -> ('a, 'err) Eta.t` with `ask`/`local`) — that is Alternative C,
not Alternative B, so even a clean result would not decide restoring R to
the central type; (2) its pre-registered kill prediction (~85%) is a
prior, not evidence. Recommendation: cancel E16 as designed. It is moot
for this decision, and its hypothesis is already covered by stronger
in-repo evidence (provide_survival's with/without pairs). If the
falsification conditions in §7 ever trigger, the replacement experiment
must be a deep-graph fixture (≥5 levels, ≥3 services, a shared dependency,
a leaf-evolution step, and a subgraph-substitution step) raced against the
composite-record envless style — not a one-service shallow port.

---

## 4. Technical analysis

All claims below marked (LAB) were compiled under OCaml 5.2.0 in a clean
lab; lab files: e1_core.ml, e1_neg_unit.ml, e6_evolution.ml, e7_boot.ml,
e8_provide.ml, e10_vr.ml, e10b_ask.ml, e12_layer.ml, e12_inf.ml,
e15_crosslib.ml, e_loophole.ml.

### 4.1 Inference and object rows

Object rows deliver exactly what V-R10 claimed. Leaves infer minimal open
requirements; `bind`/`par` unify rows automatically; a five-level chain
infers the full transitive row with zero service mentions in intermediate
bodies (LAB e1_core, compiled and executed). Boot-time completeness is
static: omitting `cache` fails at the run boundary with "The second object
type has no method cache" (LAB e7_boot). At small scale the error is good;
the repo's 20-module fixture shows it degrades to a 40-line, 2295-byte row
dump whose actionable sentence is last — versus args' 15-line "partial
application, maybe some arguments are missing" (r_dx_research/results).

Requirement-free effects are polymorphic in `'r` and that is the correct
neutral element: `(unit, 'a, 'err) t` provably does not accept a
`db`-requiring leaf (LAB e1_neg_unit), while a `'r`-parametric value runs
under any env. The brief's discoveries 1–2 are confirmed.

However, the inventory is **opt-in, not enforced**: a leaf can capture a
service in its closure while demanding nothing in the row (LAB e_loophole
compiles cleanly). R tracks the dependencies you route through it; OCaml
always offers the second, untracked channel. The "truthful summary of the
complete program" is a convention, not a guarantee.

### 4.2 The value restriction is structural

This is the most under-appreciated cost, and my lab pins the mechanism:

- Any env-reading constructor forces `'r` non-covariant. `Sync :
  ('r -> 'a) -> ...` makes `'r` "injective contravariant"; the ZIO-style
  `Ask : ('r, 'r, 'err) t` makes it "injective invariant". The compiler
  rejects covariant declarations for both (LAB e10_vr, e10b_ask). There is
  no encoding of an env-*reading* effect GADT with covariant `'r`.
- Therefore the relaxed value restriction cannot generalize the env
  parameter of an expansive expression. A top-level `let program = pure 42`
  gets a weak `'r`; its first use *instantiates* it and the second use at a
  different env fails (LAB e1_core). Every exported, reusable effect value
  needs eta-expansion — matching the repo's neg_black_box_value and
  V-Dxv4, now with the cause identified.
- Worse for Layer: a reusable layer value with an open-row requirement
  **cannot be exported from a compilation unit at all** — "The type of
  this expression ... contains the non-generalizable type variable(s)
  '_weak1, '_e", and the error variable is weak too (LAB e12_inf). Layers
  must all be thunks; thunked layers have no stable value identity;
  ZIO-style memoisation-by-reference-identity is impossible; the
  memoisation table needs explicit keys — reintroducing nominal keys the
  design was meant to avoid. Variance annotations, constructor redesign
  (Ask), aliases, and helper functions do not fix this; only thunks (or a
  PPX that writes thunks for you) do.

### 4.3 provide

`provide` type-checks and works for subtree substitution (LAB e8), but the
ordinary-OCaml equivalent — a constructor function taking the service as
an argument — does the same job, is shorter (repo measured −1/−11/−7 LOC
across three fixtures), produces better errors, and stays polymorphic for
free (a function, not a value). The repo's survival lab deleted it; I
concur. New footgun found in my lab: in an R world, a closure-capturing
leaf written `sync (fun () -> ...)` pins `'r = unit` and fails elsewhere
with a misleading "not compatible with unit" error; every leaf must
discipline itself to `fun _env ->` (LAB e8_provide). Small, but exactly
the kind of friction an extra global channel multiplies.

### 4.4 Function signatures and public .mli

Open-row thunks are the only reusable public shape (values hit VR; closed
rows reject extra capabilities — repo r_followup_research). Hover/.mli
output for rows is dense: 851 bytes/16 lines vs bag's 88/2 at 20 modules;
args' 901/32 is longest but reads as ordinary OCaml. Public guidance in an
R world converges on: hide rows behind thunks and namespaced methods —
i.e., spend effort to avoid showing the feature.

### 4.5 Modules, functors, and cross-library keys

Structural keys are global names. Two libraries demanding `db` and
`database` for the same `Db.t` silently require the app to bind both (LAB
e15); renames are breaking type changes; same-shape/different-meaning
collisions are undetectable (repo hazard_same_shape_collision.ml).
Namespacing (nested rows `env#billing#db`, PPX-mangled names) is
convention, not enforcement. The projection-functor adapter (brief item 6)
compiles but the requirement collapses to the opaque `D.env` — minimal-row
tracking is lost, and two such functors force one shared concrete env type
across libraries. That is ordinary functor DI wearing a Reader costume:
the honest version is to use functors/records directly against the envless
core.

### 4.6 Layer implementation

The brief's "missed representation" is right that horizontal composition
need not intersect rows: `both` returning a product plus `map` into an
object works, input rows unify, and `compose` statically rejects a missing
input ("no method clock") (LAB e12_layer). So Layer was indeed rejected
once on an over-broad rationale. But the corrected verdict still lands on
the repo's narrower conclusion: (1) all layer values must be thunks (VR,
§4.2); (2) thunking kills memoisation-by-identity; (3) scoped lifetime,
partial-failure cleanup, and finalizer ordering are already owned by
`with_resource`/`with_scope`/`acquire_release` in the shipped core; (4)
the repo's head-to-head found merge_explicit "not materially better than
ordinary OCaml" (37-LOC baseline). A DAG that adds parallel construction,
memoisation, and diagnostics *can* be built in the envless style as an
ordinary service-construction library over records of thunks — no env
parameter required — if a real application ever needs it. It is not a
reason to restore R.

### 4.7 What the compiler did NOT decide

Engineering assessments (not compiler-verified): the migration cost of
re-adding `'r` to the central type touches every combinator, driver,
package, test, and doc — the removal commit shows the blast radius in
reverse (~40 files). Permanence argues against re-opening that without a
forcing event. Speculation: none of the above depends on merlin/LSP hover
quality; the repo's V-RFv6 left editor DX partially open and it stays open.

---

## 5. Recommended final type and API shape

Keep and ratify the shipped design:

```ocaml
(* central type — unchanged *)
type ('a, 'err) Eta.t
```

Dependency composition and service graphs, as the public contract:

1. **Services are module-owned handle types.** Nominal identity comes from
   the module system — the cross-library problem object rows can't solve
   is already solved here.
2. **Constructors are functions returning `Eta.t`**, dependencies explicit:
   ```ocaml
   val open_ : clock -> (t, string) Eta.t
   val query : t -> string -> (string, string) Eta.t
   ```
3. **Lifetimes**: `Effect.with_resource` (body-bounded),
   `Effect.with_scope` + `Effect.acquire_release` (wider). Layer-style
   construction graphs, if ever needed, are an ordinary library over
   records of thunked constructors — parallel via `Effect.par`/`all`,
   memoised by a keyed table owned by the application.
4. **Runtime services** (clock, random, logger, tracer, meter) stay
   interpreter configuration with scoped fiber-local overrides:
   `Effect.with_clock`, `with_random`, `with_logger`, `with_tracer`,
   `with_scope`-bounded. This absorbs everything the narrowed R-channel
   was still doing at its peak.
5. **Deep-chain churn mitigation** (the one place R beat args): where a
   subsystem's dependency set is deep *and* volatile, pass a composite
   capability record per subsystem (the "bag" the DX lab measured: 88-byte
   hovers, 2 touched files per leaf evolution) — a deliberate, local
   trade of precision for stability, not a global type parameter.
6. **Islands/parallel**: explicit portable inputs, portable callbacks,
   portable tokens (`capabilities.mli`'s `random`) — unchanged.
7. **Docs**: amend `docs/services.md` with the honest tradeoff (leaf
   evolution through pure pass-through chains costs intermediate edits;
   use composite records there), cancel E16 as designed (§3.4), and add a
   short "why no R" section pointing at this verdict so the question stays
   settled.

---

## 6. Explicitly rejected alternatives

- **RESTORE R (Alternative B)**: rejected per §1. Its inference dividend
  is real but cannot cross the OxCaml portable boundary the project has
  adopted; its supporting primitives (provide, Layer) were survival-tested
  in-repo and deleted; its reusable-value story is structurally damaged by
  the value restriction; its cross-library key model is unsound without
  conventions that recreate ordinary DI.
- **Two co-equal effect types (Alternative C, `Eta.Reader` alongside)**
  : rejected. Duplicates the combinator surface, forces constant lifting,
  splits library APIs, and creates Layer ambiguity; the repo's own
  with/without labs show the wrapper buys nothing ordinary constructors
  don't; and it inherits every `'r` cost above. E16 as pre-registered
  cannot rescue it (wrong fixture, wrong hypothesis).
- **Raw cross-library object-row keys**: rejected as an ecosystem
  protocol. Global structural names, silent same-shape collisions,
  rename-is-breaking. Within one application they function; across
  libraries they are a coordination protocol with no enforcer.
- **Nominal `Key.t` + heterogeneous Context (Alternative D)**: rejected.
  Recreates Effect-TS's Tag/Context in OCaml: witness machinery, presence
  lists, ordering and duplicate hazards (repo layer_research
  gadt_presence_set), worse inference than rows, runtime lookup cost — to
  buy nominal identity that OCaml module-owned types already provide
  idiomatically.
- **Public `Layer.t`**: rejected. The product encoding type-checks (LAB
  e12), but VR forces thunk-only layers, thunking defeats
  memoisation-by-identity, and the repo's head-to-head found no material
  win over ordinary factories. Scoped acquisition/release semantics
  already ship in the core.
- **`Effect.provide`**: stays deleted (V-RPv5, re-verified LAB e8).
- **E16 Reader race as designed**: cancelled — one-service shallow
  fixture, tests Alternative C not B, sealed prediction is not evidence.

---

## 7. Falsification conditions

Reopen this decision only on specific, measurable evidence:

1. **Real-application churn proof.** A production Eta application (not a
   synthetic fixture) in which leaf-dependency changes repeatedly force
   ≥5 intermediate-file edits per change, ≥3 times in a quarter, *after*
   the composite-record pattern of §5.5 has been applied and documented.
   The application codebase becomes the race fixture.
2. **OxCaml portable objects.** OxCaml ships compiler-checkable portable
   object kinds or portable row polymorphism (the explicit "would change
   if" clause of V-Recovery-R2). Retest the R2 fixtures at the portable
   boundary.
3. **A real cross-library ecosystem.** ≥5 independently maintained
   Eta-consuming libraries whose users must repeatedly wire the same
   transitive services — evidence that auto-DI demand exists at ecosystem
   scale rather than inside one application.
4. **A provide-forcing fixture.** A concrete use case requiring mid-tree
   dynamic environment replacement with full scoped/supervised semantics
   that constructors, arguments, and separate `Runtime.run` boundaries
   cannot express (the provide_survival reopening criterion).
5. **A service-graph forcing case.** An application whose boot graph needs
   parallel construction, memoised shared subgraphs, and partial-failure
   cleanup *beyond* what `with_scope` + `par` + a keyed thunk table
   express cleanly — the trigger for building the envless DAG library of
   §5.3, evaluated before any R reopening.
6. **Language-level VR relief.** OCaml adopts a value-restriction
   relaxation that generalizes non-covariant parameters (currently not on
   any roadmap); then re-run LAB e10/e12.

Until one of these fires, the architecture is settled: `('a, 'err) Eta.t`,
ordinary OCaml dependencies, runtime-owned services, no R, no Layer, no
provide.
