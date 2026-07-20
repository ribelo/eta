# DX-E26 Journal — `Effect.fresh`

## V-DX-E26-001 — Sealed predictions

Status: PENDING

### Decision and scope

Decide whether Eta should promote the one-pager's runtime-owned, per-runtime
monotonic counter as `Effect.fresh` and `Effect.fresh_named`, rather than leave
callers to use `Random` or hand-roll mutable counters. The counter is deliberately
separate from the process-global counters used for tracer context IDs, interrupt
IDs, service keys, typed-failure keys, and runtime IDs.

Provenance: the capability vocabulary is imported from fused-effects
`Control.Effect.Fresh`; Eta's runtime ownership, portability, and API contract are
evaluated independently here.

### Proof obligations

| ID | Proof question | Evidence | Risk | Predicted result |
| --- | --- | --- | --- | --- |
| P1 | Does one runtime return a strictly increasing sequence? | Focused native and jsoo tests | Low | Yes; first value is `1` and each pull advances once. |
| P2 | Are concurrent pulls unique? | `Effect.map_par`/`all` contention test | Medium | Yes; native uses an atomic counter and jsoo uses one runtime-local mutable cell. |
| P3 | Is replay deterministic in `Eta_test`? | Run the same program against two freshly created test runtimes | Low | Yes; each fresh runtime starts its counter at zero. |
| P4 | Is the non-global boundary visible and true? | Two-runtime red-team fixture plus `.mli` inspection | Medium | Yes; both runtimes can return `1`, and the docs warn that callers must namespace cross-runtime correlation IDs. |
| P5 | Is `fresh_named` exactly formatting over `fresh`? | Shape test and implementation inspection | Low | Yes; `fresh_named "worker"` yields `"worker-1"` on a fresh runtime and consumes the same counter. |
| P6 | Do both supported backends integrate without portability regressions? | Four required Nix gates | Medium | Yes; native/OxCaml and js_of_ocaml targets compile. |

### Hypothesis ledger

| Candidate | Strongest case | Evidence needed to win | Falsifier | Initial status |
| --- | --- | --- | --- | --- |
| A. First-class `Effect.fresh` capability | Centralizes runtime ownership, deterministic replay, and concurrent uniqueness in one honest leaf. | P1–P6 pass with a small implementation. | Duplicate values within one runtime, nondeterministic test replay, backend failure, or misleading global-ID ergonomics. | Favored, unproven |
| B. Caller-owned counter | Ordinary OCaml state is explicit and can be sufficient within one module. | Realistic call site is no worse and safely handles concurrency/reset/ownership. | Review pair shows repeated synchronization and lifecycle plumbing that A removes. | Active baseline |
| C. Runtime `Random` DIY | Already runtime-owned and portable; random-looking IDs may avoid a new construct. | Deterministic, collision-free concurrent IDs with equally clear semantics. | Random draws cannot prove uniqueness and couple identity allocation to unrelated schedule randomness. | Active baseline |

### Sealed quantitative predictions

- Construct census: **+2 values** (`fresh`, `fresh_named`) and **+1 concept**
  (runtime-owned fresh counter).
- Footgun census: **+0 unresolved footguns**. One trap candidate is expected:
  treating values as globally unique. The public `.mli` must explicitly state
  that distinct runtimes and domains may repeat values and that cross-runtime
  correlation requires caller-owned namespacing.
- Implementation shape: one per-runtime native atomic counter; one plain mutable
  cell per jsoo runtime; `fresh_named` allocates only its result string and uses
  no second counter.
- Expected recommendation: **promote**. `Random` DIY is predicted inadequate
  because deterministic random streams are not uniqueness proofs and consuming
  them perturbs unrelated jitter/replay behavior.

### Disconfirming evidence sought

The favored design loses if contention produces a duplicate, two fresh test
runtimes do not replay the same sequence, jsoo requires a nonportable primitive,
or the realistic call-site pair shows no meaningful reduction over an ordinary
caller-owned counter. The `Random` baseline gets a fair comparison on uniqueness,
determinism, coupling, and call-site burden.

### Planned artifacts and commands

- Regression tests for P1–P5 in the core/common, eta-test, and jsoo surfaces.
- Red-team evidence under `redteam/` for cross-runtime collision and contended
  `map_par` uniqueness.
- Review pair and reviewer questions under `review/`.
- Exact final gates:
  - `nix develop -c dune build @install`
  - `nix develop -c dune runtest --force`
  - `nix develop -c eta-oxcaml-test-shipped`
  - `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo`

No production code or public contract has been changed at this seal point.

## V-DX-E26-002 — Implementation verdict

Status: ACCEPT

Decision: promote the one-pager's `Effect.fresh` / `Effect.fresh_named` slice.

Evidence:

- `lib/eta/effect.mli` and `lib/eta/runtime_contract.mli` state the per-runtime,
  non-global, deterministic-test, and shared-counter contracts.
- Native core tests prove `[1;2;3]`, 128-way `Effect.all` uniqueness, and
  `"worker-7"` formatting from the same counter.
- `Eta_test` proves two newly created runtimes replay `[1;2;3]`.
- `redteam/two-runtimes.md` demonstrates the intentional cross-runtime collision.
- `redteam/contention.md` records 10,000/10,000 unique `map_par` pulls at
  `max_concurrent=64` (0.958 ms local elapsed on Linux 7.1.3 x86_64).
- The jsoo Node suite observes `[1;2;3]` then `"worker-4"` from a plain mutable
  runtime-local cell.

Verification (all exited 0):

```text
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
nix develop .#mainline -c dune runtest test/js_jsoo --force
```

Hypothesis ledger final status:

| Candidate | Final status | Evidence |
| --- | --- | --- |
| A. First-class `Effect.fresh` capability | ACCEPTED | All six proof obligations passed; call site removes counter synchronization/reset plumbing. |
| B. Caller-owned counter | DOMINATED for runtime-local IDs; still valid out of scope for wider namespaces | `review/worker-spawn-old.ml` vs `worker-spawn-new.ml`; global namespacing remains application-owned. |
| C. Runtime `Random` DIY | REJECTED | It cannot guarantee uniqueness and perturbs unrelated schedule randomness/replay. |

Prediction result: construct census +2 values / +1 concept, exactly predicted;
unresolved footguns +0, exactly predicted. The global-ID trap candidate was real,
the two-runtime fixture reproduced it, and the `.mli` warns before use. Score:
5/5 (`report.md`).

Counterevidence considered: two runtimes collide immediately, so this API is
unsafe when silently substituted for a global correlation namespace. That does
not contradict the selected contract; it is the explicitly documented boundary.

Remaining uncertainty: the local contention time is not a portable benchmark and
is not used as a performance guarantee. It was collected only to show that the
tight concurrent path completed with no duplicates. No proof result depends on a
timing threshold.

Implementation follow-up: code, public contracts, regression tests, red-team
artifacts, and the review packet now agree. The pre-existing global counters were
left untouched as required.
