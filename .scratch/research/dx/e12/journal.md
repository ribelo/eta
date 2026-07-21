# DX-E12 Journal — `Effect.audit` / `Effect.describe`

Branch: `research/dx-e12-audit-describe`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e12`
Phase: D (runtime & model)

## Predictions (sealed)

Sealed before documentation, implementation, test, manifest, or example edits.
Wrong predictions remain as evidence; this section will not be edited after its
commit.

### Decision and proof obligations

Decision: whether static blueprint introspection is honest and useful enough to
ship as `Effect.audit` / `Effect.describe`, and whether `audit` is informative
enough to act as an examples manifest rather than only a local preflight.

| # | Proof question | Evidence needed | Risk | Predicted result |
| --- | --- | --- | --- | --- |
| E12-P1 | Can every library leaf declare a stable capability footprint without inspecting its evaluator? | Constructor census plus build | Medium | Proven |
| E12-P2 | Do flags compose through static `Map`, `Bind` spines and opaque wrapper leaves without forcing continuations? | Generated-blueprint properties | High | Proven for the documented class |
| E12-P3 | Does `uses_clock = false` survive a poisoned-clock runtime, and does `emits_logs = false` keep a recorder silent? | Runtime properties | High | Proven for the documented class |
| E12-P4 | Is the opaque-bind limitation visible enough to prevent a false runtime-inventory reading? | MLI review plus adversarial handler | High | Limitation reproduced and warning judged adequate |
| E12-P5 | Do flags make the 54 example names easier to verify rather than misleading readers? | Generated golden manifest review | High | Mostly informative; a minority of static false negatives will be explainable by bind continuations |

The falsifier for promotion is not implementation difficulty. It is an API
contract that cannot state, in the first paragraph and per flag, that only the
static spine and declared library-leaf footprints are covered. The falsifier
for the manifest role is a 54-example golden whose apparent capability claims
regularly contradict what a reader reasonably expects from the example name.

### Predicted representation and composition

I predict one private capability-footprint record on `Custom`, using the same six
booleans as the public audit minus `names`. `make` will accept the footprint for
an opaque leaf. `preserve` will union any wrapper's directly declared footprint
with its inner effect's footprint. This is required for wrappers such as
`delay`, `timed`, timeout, retry/repeat, resources, and `daemon`: inheriting only
the wrapper or only the child would both be observably wrong.

`Pure` and `Fail` contribute no footprint. `Map` traverses its inner node. `Bind`
traverses only its already-built `inner` and never calls `k`; therefore a sleep,
log, metric, resource, fork, or daemon constructed by `k` is absent until normal
runtime execution constructs it. I predict no safe generic technique can recover
that missing continuation footprint without executing user code, so the honest
API must preserve the blind spot rather than simulate an inventory.

Predicted direct flag sources:

- `uses_clock`: clock reads/sleeps and wrappers that perform them, including
  sleep/now, delay/timed/timeout, retry/repeat, timestamps from spans/events/logs,
  and metrics;
- `emits_logs`: log leaves only (wrappers inherit);
- `emits_metrics`: metric update leaves only (wrappers inherit);
- `has_concurrency`: combinators or supervisor leaves that create concurrent
  fibers, including race/par/all/map-par, timeout, and structured background;
- `has_resources`: lifecycle leaves that register/run finalizers or establish
  Eta resource scope, including acquire/release and body-bounded resource use;
- `has_background`: runtime-owned `daemon` only; structured background remains
  concurrency but not work that outlives its lexical owner.

I predict conservative means **may over-report behavior actually observed in one
run**: disabled log/metric/tracing capabilities, failed predecessors, empty
collections, schedule completion, or untaken branches can suppress operations
whose static leaf footprint remains true. The audit can also under-report only
at the explicitly documented opaque-continuation / undeclared-Expert boundary.
For the generated declared-leaf class, a false flag predicts absence strongly
enough for poisoned-capability and silent-recorder tests.

### Predicted `describe` shape and corpus

I predict a deterministic, multiline tree using representation-level node names
for `Pure`, `Fail`, `Map`, and named/anonymous custom leaves. `Bind` will print
its visible inner child and a literal `<bind …>` marker instead of forcing `k`.
Opaque wrapper leaves will remain leaves: the representation does not retain an
inspectable child tree after `preserve`, so names and footprint are visible but
not fabricated structure.

The snapshot corpus will contain at least these diagnostic shapes: a pure/map
chain; named and anonymous leaves; nested binds with one marker per opaque
continuation; par/all/race/map-par concurrent leaves; resource and background
leaves; and `fold` / `bind_error` compositions. I predict the snapshots will make
the blueprint model clearer than prose alone, but will also expose that several
high-level combinators collapse to custom leaves.

### Predicted public-surface census

| Cluster | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Effect introspection values | 2 (`name`, `collect_names`) | 4 | **+2** |
| Effect public introspection types | 0 | 1 | **+1** |
| Eta_test audit assertions | 0 | At least 6 | **+6 or more** |
| New footguns | 0 | 0 | **+0** |

The assertion vocabulary is predicted to include all six negative capability
claims plus `assert_pure_eff`; exact aliases may be reduced if they duplicate a
clearer primitive. `assert_pure_eff` is predicted to mean no declared capability
footprint, not semantic referential transparency of arbitrary `sync` or opaque
continuation code.

Footgun prediction: **+0**, conditional on the opaque-lambda trap being stated
directly beside `audit` and assertions. The trap exists in the model regardless;
the experiment succeeds only if documentation disarms rather than hides it.

### Predicted examples manifest

The checked-in corpus has exactly **54** top-level `examples/*.ml` programs. I
predict the regeneration script can produce one stable golden row/file per
program without editing example source. Most rows will align with names:
observability/log examples declare log/clock behavior, metric examples declare
metrics/clock, timeout/retry/repeat examples declare clock, concurrency examples
declare concurrency, resource examples declare resources, and daemon examples
declare background.

I predict at least one surprising false negative caused by an effect created only
inside `bind`/`let*`, because the examples are ordinary programs rather than the
restricted property-test class. If those surprises dominate or require readers
to mentally execute each program before trusting a row, recommend killing the
manifest role while retaining local audit assertions. Otherwise recommend
promoting both APIs and keeping the manifest as explicit evidence of the static
contract.

### Predicted review outcome

Using 1 = reject and 5 = approve, I predict the `describe`-based lesson earns
**4/5 or better**, versus **3/5** for prose alone. The expected correct answer to
“what does `uses_clock = false` guarantee?” is: no clock footprint occurs in the
currently inspectable static spine or declared library leaves; it says nothing
about effects later returned by opaque continuations or undeclared expert code.

Likeliest reviewer misreadings:

1. “`audit` inventories everything that can happen at runtime.” It does not;
   ordinary continuation functions are not forced.
2. “A true flag means the capability will be observed on every execution.” It
   does not; true is conservative static possibility, and runtime configuration
   or control flow may prevent the operation.

### Promote / hold / kill prior

Predict **PROMOTE** when properties, snapshots, red-team probes, exact Nix gates,
and a tutorial rating of at least 4 are green. Predict retaining `audit` as local
preflight but **KILLING its manifest role** if the 54 generated example entries
mislead more than inform. Stop rather than weaken the contract if preserving
flags through all library leaves requires forcing user continuations or claiming
runtime completeness.

---

## Execution log

### V-DX-E12-001 — Predictions sealed

This prediction section was created before E12 documentation, implementation,
tests, manifests, or example changes. Later entries will record evidence without
editing the sealed predictions above.

### V-DX-E12-002 — Docs-first contract

Status: ACCEPT.

`Effect.audit`, `Effect.describe`, the seven `Eta_test` assertions, flag
directionality, and the opaque-continuation limitation were documented in the
public interfaces before implementation. `Expert.make` now requires an explicit
capability declaration; statically available wrapped children are passed with
`inherit_` and unioned. `Background` implies concurrency, preventing an invalid
public flag combination.

### V-DX-E12-003 — Static model and properties

Status: ACCEPT for the documented blueprint class.

- `Custom` stores a private six-boolean footprint.
- `preserve` unions wrapper and child footprints.
- `Map` and the input side of `Bind` retain visible footprints; continuations
  are not called.
- A recursive deterministic generator produces 168 blueprints from eight base
  leaves through two levels of map, named, preserve-backed uninterruptible, and
  parallel composition.
- For every generated false clock flag, execution with a poisoned Eta clock did
  not reach that clock. For every false log flag, a recording logger stayed
  empty.
- Focused declarations cover all six flags, empty `Expert.make`, inherited
  custom children, background/concurrency consistency, retry, resources,
  concurrency, logs, metrics, clock, and daemon behavior.

The generator intentionally excludes arbitrary continuation functions. The
separate red-team fixture proves why that exclusion is necessary.

### V-DX-E12-004 — Describe corpus and assertions

Status: ACCEPT.

`test/effect_introspection/expected_descriptions.txt` pins 11 cases: pure/map,
named leaf, nested binds, par/all/race/map-par, fold, bind_error, resource, and
background. Every bind continuation is rendered as literal `<bind …>`.

`Eta_test` exposes seven executable checks: the six negative capability
assertions plus `assert_pure_eff`. Their contracts repeat the static-spine
boundary and define “pure” as no declared Eta capability footprint, not
referential transparency.

### V-DX-E12-005 — Examples manifest

Status: REJECT as a product manifest role; ACCEPT as experiment evidence.

The regeneration script instruments copies of all 54 committed examples and
calls the real `Effect.audit` on the exact effect passed to each supported,
reached runtime boundary. It records 71 boundaries and four programs with no
Eta runtime boundary. Nonzero exits and timeouts fail generation.

The output is mechanically faithful but several rows are predictably poor
reader manifests. `resource_retry` reports no clock, `cli_business` reports no
capabilities, `channel_probe` / `queue_probe` report no concurrency, and the
observability examples miss metrics constructed after binds. These are central,
not incidental, expectations from the filenames. The sealed prediction that
only a minority of surprises would remain was too optimistic. Keep the golden
as evidence for the static boundary; do not promote `audit` as an examples
inventory.

### V-DX-E12-006 — Red-team and teaching review

Status: PARTIAL promotion evidence.

The opaque-bind executable reports:

```text
hidden-bind uses_clock=false runtime_sleeps=1
preserve-wrapped uses_clock=true
```

The first result falsifies any runtime-inventory interpretation. The second
proves preserve inheritance. The public MLI warning predicts the attack exactly.

The executor rubric rates prose teaching 3/5 and real `describe` teaching 4/5.
An independent technical review rates them 4/5 and 5/5 respectively: the literal
marker, absent sleep, and false-clock consequence make the boundary directly
inspectable. The >=4 promotion gate is met.

### V-DX-E12-007 — Recommendation

Status: ACCEPT API, REJECT manifest role.

Promote `audit`, `describe`, and the explicitly static `Eta_test` assertions.
Kill `audit`'s product/examples-manifest role and feed the observed dynamic-bind
gap to DX-E17. The strongest remaining risk is naming: `assert_no_clock` can
sound stronger than its contract when read without documentation, even though
the MLI, failure output, snapshots, and red-team packet make the boundary
explicit.

### V-DX-E12-008 — Exact gates

Status: ACCEPT.

All required commands passed after the independent review fixes:

```text
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
```

The final manifest regeneration also passed with 54 headers, 71 reached runtime
boundaries, four no-boundary entries, and fail-loudly process handling.
