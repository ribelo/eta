# Eta Crux and Bonsai performance comparison plan

Date: 2026-08-09

## Result

Eta Crux and Bonsai overlap at the incremental computation layer. They do not
overlap at Eta's transport, capacity, request, telemetry, or serialized-session
layers.

The strongest comparisons are:

1. One state-machine action followed by one stable output.
2. An action that returns an equal model.
3. One changed child in a keyed collection.
4. Root construction and the first stable output.

The headline comparison must use the production drivers and one common native
measurement harness. `Bonsai_bench` is useful for scenario construction and
cross-checks. Its automatic recompute steps prevent a direct comparison with
the current Eta action workload.

Current Bonsai cannot use Eta's installed package set. The current Bonsai
release requires `oxcaml-compiler.5.2.0minus38`. Eta's Nix shell contains
`oxcaml-compiler.5.2.0minus31`.

Use a separate `5.2.0minus38` switch for the current-source comparison. Build
both Eta and Bonsai in that switch. An older Bonsai preview can use Eta's
compiler, but that result is not a current-source comparison.

## Source identities

All paths in this table existed on 2026-08-09. Each Git checkout identity came
from `git rev-parse HEAD`, `git remote -v`, and `git status --short --branch`.

| Source | Local identity | Use |
|---|---|---|
| Eta | `/home/ribelo/projects/ribelo/ocaml/Eta` at `5affc1786b61c18849be27951d1882e49f3e45af` | System under comparison |
| Eta benchmark | `lib/crux/bench/bench_eta_crux.ml`, SHA-256 `6b8a97552f0cd2c64b8b2ab3cdb4310353eb1992727913304cfe9514641f1efa` | Current workload and metric definitions |
| Bonsai | `/home/ribelo/projects/github/bonsai` at `1e4682c1312e737aa94554139a28ebcd0c077bd6` | Current computation and driver source |
| Incremental | `/home/ribelo/projects/github/incremental` at `2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6` | Bonsai engine semantics |
| Oxmono | `/home/ribelo/projects/github/oxmono` at `4e3b745fb95d66fa0e13601d7fa7aeaed7962043` | Bonsai package, benchmark, and Core_bench sources |

The Bonsai and Incremental commits both identify themselves as
`v0.18~preview.130.100+614` in their commit objects. Their public-release
commits have the same timestamp. The Bonsai and Incremental working trees were
clean.

Oxmono is an independent aggregate checkout from
[`avsm/oxmono`](https://github.com/avsm/oxmono). Its Bonsai files are not
byte-identical to the separate Bonsai checkout. Therefore, this report uses
Oxmono only to identify the benchmark API. A benchmark run must use one matched
published package set.

Pin the current-source run to these package artifacts:

| Package | Version | Published source |
|---|---|---|
| `bonsai` | `v0.18~preview.130.100+614` | commit [`d0970ff1f66ee9debaf1ff86ec34f5a96c8fc91c`](https://github.com/janestreet/bonsai/commit/d0970ff1f66ee9debaf1ff86ec34f5a96c8fc91c), SHA-256 `2def08764546d53ce106732e4948d639e7d90c0d3afb96382d09bc2d5ce86383` |
| `incremental` | `v0.18~preview.130.100+614` | commit [`7550af45c759767390478ae38ce9943f513dd181`](https://github.com/janestreet/incremental/commit/7550af45c759767390478ae38ce9943f513dd181), SHA-256 `ce5d3219a54e403b8ad15d9f0d0c3cf469ce1521b1d8c58648768d71783489ae` |
| `bonsai_bench` | `v0.18~preview.130.100+614` | commit [`0beb1b3dc308ad32dbd5c0a1429ceddfeb7b8d05`](https://github.com/janestreet/bonsai_bench/commit/0beb1b3dc308ad32dbd5c0a1429ceddfeb7b8d05), SHA-256 `aac6f4f36871192f0c90497710170a9a642b382f4c36b26c7015d83d9a02183a` |

The package version is the reproducible identity for the run. The separate
local Bonsai checkout remains the primary source for API analysis. The package
archive commit differs from that checkout's release commit.

The artifact URLs, hashes, exact peer dependencies, and compiler conflicts
come from the official package records. The records were read with
`opam show --raw PACKAGE.VERSION`.

## True semantic overlap

### Shared computation boundary

Both systems provide:

- a root computation with a typed result,
- framework-owned local state machines,
- deferred action injection,
- explicit incremental stabilization,
- cutoffs that stop equal values,
- dynamic structure,
- keyed child computations with stable state,
- framework-required work after graph evaluation.

Both systems expose lifecycle concepts, but their removal-completion boundaries
do not overlap. Eta cancels a scoped job and permits cleanup to settle
asynchronously. Bonsai runs explicit deactivation and activation effects during
`trigger_lifecycles`. Lifecycle replacement is therefore excluded from the
quantitative comparison.

Bonsai's driver documents its production loop as `flush`, `result`, and
`trigger_lifecycles`. `flush` processes pending actions and stabilizes the
Incremental graph. Lifecycle order is deactivation, activation, then
after-display work. See
[`bonsai_driver.mli`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/driver/bonsai_driver.mli#L17-L40).

Eta's root selects one ingress event, stabilizes its private graph, and installs
one committed output. Eta exposes post-commit work separately. See
[`eta_crux.mli`](../../../lib/crux/eta_crux.mli) `Root`.

The driver adds output delivery and completion. See
[`eta_crux.mli`](../../../lib/crux/eta_crux.mli) `Driver`.
This delivery protocol is an Eta cost, not a Bonsai graph operation.

### Comparable operation

The common end-to-end operation is:

1. Inject one typed action.
2. Process that action.
3. Stabilize the incremental graph.
4. Obtain and inspect the typed root result.
5. Run the required lifecycle-dispatch or post-commit step.
6. Finish all completion steps that permit the next operation.

For Bonsai, use `Bonsai_driver.schedule_event`, `flush`, `result`, and
`trigger_lifecycles`. For Eta, use `Endpoint.send`, `Root.advance`, the committed
output, and `Post_commit.start`.

This root boundary is the primary comparison. Both paths include one input
queue, one state transition, a production-driver cycle, typed output, and the
required empty post-step. One cycle means one `Root.advance` or one
`Bonsai_driver.flush`; it does not assert the same number of private engine
stabilization calls. The pinned Bonsai driver can stabilize more than once
inside one `flush`.

Eta `Driver.poll` adds an output-delivery fence and an acknowledgement. Bonsai
has no matching fence. Report this Eta driver cost as a secondary product row.

### Selected measurement seam

The common harness accepts one adapter function:

```ocaml
val run_batch : operations:int -> counters
```

Each steady-state adapter runs all sample operations on one live graph. The Eta
adapter runs the batch inside one Eta runtime call. The Bonsai adapter runs the
batch inside one driver instance. Startup uses one fresh root per timed
operation and excludes teardown from the summed timed intervals.

This seam does not charge Eta for one top-level runtime start per action.
Production Eta programs keep the runtime alive across actions. Both adapters
still use their public input and advancement operations for each action.

The runner calibrates an operation count independently for each adapter and
workload. This keeps every sample above the duration floor when implementations
differ by orders of magnitude. Results are normalized per operation, and raw
operation counts are published. The runner rejects a sample when its semantic
counters differ from the expected counters.

### Incremental engine overlap

Incremental states that `Var.set` does not recompute immediately.
`stabilize` updates the necessary observed graph. See
[`incremental_intf.ml`](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml).

Eta exposes the same relevant concepts through `map`, `both`, `cutoff`, `bind`,
`State_machine`, and `Assoc`. See [`eta_crux.mli`](../../../lib/crux/eta_crux.mli).

These shared laws support equal-model and keyed-change comparisons. Private
node layouts, optimizer passes, and path encodings are implementation details.

## Bonsai production and benchmark APIs

### Production driver

`Bonsai_driver.create` constructs a production driver from a graph function and
a time source. The driver provides:

- `schedule_event` for effect and action injection,
- `flush` for pending actions and stabilization,
- `result` for typed output observation,
- `trigger_lifecycles` for lifecycle effects,
- `Expert.invalidate_observers` for teardown,
- `Expert.reset_model_to_default` for benchmark-only reset.

The source explicitly marks model reset as benchmark-only. See
[`bonsai_driver.mli`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/driver/bonsai_driver.mli#L50-L83).

### Scenario API

`Bonsai_bench_scenario` provides precomputed inputs and these interactions:

- `change_input` and `update_input`,
- `inject`,
- `advance_clock_by`,
- `recompute`,
- `reset_model`,
- `profile`,
- `many` and `many_with_recomputes`.

The input API requires all future input values to be computed before timing.
This rule prevents input preparation from changing the result. See
[`bonsai_bench_scenario.mli`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/bench_scenario/bonsai_bench_scenario.mli#L3-L82).

`Interaction.recompute` calls `Bonsai_driver.flush` and
`trigger_lifecycles`. It intentionally does not fetch the result. See
[`bonsai_bench_scenario.ml`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/bench_scenario/bonsai_bench_scenario.ml#L48-L64).

### `Bonsai_bench`

`Bonsai_bench.create` measures repeated interactions on one shared computation.
The interaction must be idempotent or keep similar cost across repetitions.
`create_for_startup` measures construction and first stabilization. See the
[`Bonsai_bench` interface](https://github.com/janestreet/bonsai_bench/blob/0beb1b3dc308ad32dbd5c0a1429ceddfeb7b8d05/src/bonsai_bench.mli).

`compare_startup` and `compare_interactions` run common scenarios over several
computation implementations. `run_via_command` and `run_sets_via_command`
provide Core_bench command-line control and machine output.

The runner inserts `recompute` before and after every interaction sequence. It
then removes adjacent duplicate recomputes. See
[`runner.ml`](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/bonsai_bench/src/runner.ml#L16-L53).

As a result, an action operation includes an empty leading recompute and the
action recompute. Eta's current action workload includes only the action
advancement. These two measurements are not directly comparable.

The Bonsai guide also states that `bonsai_bench` uses `Bonsai_driver`, not the
full browser runtime. It excludes VDOM diffing, patching, layout, and style
work. See
[`benchmarking.md`](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/bonsai_web/docs/how_to/benchmarking.md#L1-L11).

### Core_bench measurements

Core_bench stabilizes the major heap before measurement. It records runs,
nanoseconds, cycles, minor words, major words, promoted words, collections,
and compactions for each sample. Its native sampler increases the run count
with a linear or geometric schedule. See
[`benchmark.ml`](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/core_bench/src/benchmark.ml#L20-L29)
and
[`benchmark.ml`](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/core_bench/src/benchmark.ml#L71-L182).

`bonsai_bench` invalidates old observers between benchmarks and runs a full
major collection. See
[`bonsai_bench.ml`](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/bonsai_bench/src/bonsai_bench.ml#L7-L19).

## Comparable workload matrix

| Workload | Eta source workload | Bonsai equivalent | Status |
|---|---|---|---|
| State action | `action.complete_advancement` | state machine, `schedule_event`, `flush`, `result`, lifecycle | Headline |
| Equal model | `incremental.equal_model` | action returns the same model with an equality function, then observe a dependent projection | Headline |
| Keyed change, 1,000 | same keyed scenario at a smaller size | `Bonsai.assoc` over 1,000 entries | Headline scaling point |
| Keyed change, 10,000 | `assoc.changed_child.10000` | `Bonsai.assoc` over 10,000 entries, change the middle value | Headline |
| Keyed change, 100,000 | `assoc.changed_child.100000` | same scenario with 100,000 entries | Not run: the 10,000-key smoke sample allocated about 300 million words per operation |
| Startup | not present | `create_for_startup` semantics | Add to the comparison plan |
| Key entry and removal | `lifecycle.overlapping_cleanup` | Bonsai deactivation and activation effects | Excluded: completion boundaries differ |
| Persistent output diff | `adapter.persistent_output.*` | observe the output map and compute one symmetric difference | Secondary |

The current Eta workload definitions and assertions are in
[`bench_eta_crux.ml`](../../../lib/crux/bench/bench_eta_crux.ml).

### Workload requirements

**State action.** Start with model `0`. Inject integer `1`. Observe model `1`.
The transition schedules no application work.

**Equal model.** Inject one action that returns the existing model. Observe a
dependent projection and require zero projection executions after setup.

**Keyed change.** Prebuild a map of integer keys and zero values. Change only
the middle key. Require one child computation and one output row to change.
Run sizes `1_000` and `10_000`. Do not run `100_000` unless the 10,000-key
allocation safety ceiling is resolved.

**Startup.** Prebuild immutable input data. Time root or driver construction,
the first production-driver cycle, the first typed result, and required empty
post-step. Report this separately from steady-state results.

**Lifecycle.** Do not report a quantitative lifecycle ratio. Eta removal
cancels a scoped job and can return before cleanup settles. Bonsai's
`trigger_lifecycles` synchronously runs deactivation and activation effects.
Adding a settlement fence to Eta would measure a boundary that Bonsai does not
have.

**Persistent output.** Compute a complete symmetric difference after result
observation. Report graph time and graph-plus-diff time separately. Different
map implementations make this a secondary result.

## Excluded non-overlap

Do not present these Eta workloads as Bonsai comparisons:

| Eta workload | Reason |
|---|---|
| `driver.identity` | Bonsai has no identity-versus-serialized binding choice |
| `driver.serialized.*` | Serialization, wire framing, acknowledgement, and payload size are Eta transport concerns |
| `telemetry.*` | Eta observability suppression has no matching Bonsai contract |
| `capacity.ingress.*` | Bonsai does not expose Eta's bounded ingress admission protocol |
| `capacity.request.*` | Bonsai has no matching host-request permit protocol |
| `capacity.serialized_handles` | Remote handle freshness, session replacement, and collection are Eta wire semantics |
| blocked `lifecycle.overlapping_cleanup` | Bonsai lifecycle starts UI effects but does not define Eta's scoped acquire-release settlement |

Also exclude DOM, VDOM, browser events, layout, CSS, JavaScript, and Wasm.
Eta Crux has no matching renderer. Bonsai's official benchmark guide excludes
these costs too.

Do not compare static node counts or private path representations. They are not
equivalent units.

## Fairness rules

### Setup exclusion

- Build maps, action arrays, expected outputs, codecs, and scenario values
  before timing.
- Construct one live root per steady-state sample series.
- Exclude root construction from steady-state measurements.
- Include all construction only in the startup workload.
- Exclude benchmark registration, command parsing, printing, JSON, and file I/O.
- Teardown observers, drivers, and switches after the sample series.

### Action injection

- Inject exactly one typed action per operation.
- Include the public production injection call.
- Do not call a state transition directly.
- Do not include action creation or random selection.
- Use the same integer action and initial state.

### Stabilization and advance

- Process exactly one eligible action per operation.
- Perform the complete reusable production-driver cycle.
- Treat one `Root.advance` and one `Bonsai_driver.flush` as one cycle. Do not
  claim that the private engines execute the same stabilization count.
- Do not use `Bonsai_bench` bookend recomputes for headline timing.
- Count production-driver cycles and committed observations as semantic
  counters.

### Output observation

- Read the typed root result inside the timed operation.
- Force the changed integer or middle map entry with `Sys.opaque_identity`.
- Do not format, serialize, print, hash, or traverse the complete map.
- For the output-diff workload only, include one complete symmetric diff.
- Complete Eta's post-commit token before the operation ends.
- Include delivery acknowledgement only in the secondary Eta driver row.

### Lifecycle and effects

- Include the empty lifecycle or post-commit dispatch that production requires
  before the next action.
- Use no application effects for the common workloads.
- Require no pending background work at the operation boundary.
- Do not compare external I/O, Eio scheduling, Deferred jobs, timers, or blocked cleanup.
- Exclude lifecycle entry and removal because completion boundaries differ.

### Garbage collection

- Use the same native compiler, runtime, GC parameters, and environment.
- Keep each steady-state graph alive across measured operations.
- Run the same major-heap stabilization before each sample.
- Do not run collection inside the timed interval.
- Record minor, major, and promoted words per operation.
- Record minor and major collections per operation.
- Report compactions when they occur.

The current Eta harness runs `Gc.compact` before each sample and reads
`Gc.counters` around the timed loop. See
[`bench_eta_crux.ml`](../../../lib/crux/bench/bench_eta_crux.ml)
`measure_workload`.

### Sample scheduling

- Use one common measurement harness for both systems.
- Use 5 untimed warmup samples and at least 31 measured samples.
- Calibrate one operation count for each adapter and workload.
- Publish every calibrated count beside the raw samples.
- Require at least 50 ms per sample.
- Alternate system order with an `ABBA` schedule.
- Run each system in a fresh process for each outer repetition.
- Store every raw sample.
- Use a fixed seed for any order randomization.

This policy avoids the different Core_bench and Eta calibration schedules. It
also avoids sub-duration samples when the adapters differ greatly. Startup
operations use isolated roots: each construction is timed separately, teardown
is excluded, and timed intervals are summed into one sample.

### CPU and host

- Run native executables on the same machine and kernel.
- Pin the process to one isolated physical CPU with `taskset`.
- Keep the same CPU governor and turbo policy for both systems.
- Record the CPU model, microcode, kernel, governor, turbo state, and affinity.
- Stop unrelated load or record it as a failed run.
- Do not compare Node results with native Eta results.

### Metrics

Report these primary metrics:

- wall nanoseconds per complete operation,
- minor allocated words per operation,
- major allocated words per operation,
- promoted words per operation,
- minor and major collections per operation.

Report median, mean, standard deviation, p95, minimum, and maximum. Publish raw
samples and operations per sample.

Report these semantic counters beside the measurements:

- actions injected and applied,
- production-driver cycles,
- commits and result observations,
- dependent projection executions,
- keyed child visits,
- changed output rows.

CPU cycles per operation are optional. Use them only when the host provides a
stable invariant counter. Resident memory and retained heap require separate
setup-size measurements.

## Compiler and package assessment

The Eta Nix shell reported:

```text
ocamlc                 5.2.0+ox
oxcaml-compiler        5.2.0minus31
dune                   3.22.2+ox
core                   v0.18~preview.130.91+190
incremental            v0.18~preview.130.91+190
incr_map               v0.18~preview.130.91+190
ppx_jane               v0.18~preview.130.91+190
ppxlib                 0.33.0+ox1
```

The shell did not contain `bonsai`, `bonsai_concrete`, `virtual_dom`,
`core_bench`, `command_nodejs`, `expectable`, or the `js_of_ocaml-ppx` findlib
library.

A direct native Dune build of the current Bonsai checkout used an external
build directory. It failed on these missing libraries. It also found a PPX
warning after it combined preview-100 source with preview-91 dependencies.
This is an invalid mixed package set.

The official preview-100 records require every Jane Street peer at
`v0.18~preview.130.100+614`. They also contain:

```text
conflicts: [ "oxcaml-compiler" {!= "5.2.0minus38"} ]
```

Therefore, current Bonsai needs a separate matched package environment with
`5.2.0minus38`. To preserve compiler fairness, build Eta in that environment
too. Do not compare Eta on `minus31` with Bonsai on `minus38` as the primary
result.

There is one fallback. Bonsai and `bonsai_bench`
`v0.18~preview.130.91+190` accept `oxcaml-compiler >= 5.2.0minus31`. Their
published source commits are:

- Bonsai `86e5f50d914a162e125be0a876405a7409af0e1a`
- `bonsai_bench` `97e6a573370735605623becb0147e7e5f8d343e8`

This fallback can share Eta's compiler after installation of the missing
preview-91 packages. Label it as a compiler-matched historical baseline.

## Recommended result structure

Publish three groups:

1. **Current, compiler-matched core comparison.** Build Eta commit `5affc178`
   and Bonsai preview-100 with `5.2.0minus38`.
2. **Eta-only product costs.** Keep transport, capacity, telemetry, request,
   and serialized-handle workloads in their existing suite.
3. **Optional historical control.** Run Bonsai preview-91 and Eta on
   `5.2.0minus31`.

Do not compute one aggregate score. Report each workload and metric. The
semantic counters must pass before timing results are accepted.

## Primary source index

### Eta

- [Current benchmark](../../../lib/crux/bench/bench_eta_crux.ml)
- [Public computation and driver interface](../../../lib/crux/eta_crux.mli)

### Bonsai and Incremental

- [Production driver](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/driver/bonsai_driver.mli)
- [Benchmark scenario interface](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/bench_scenario/bonsai_bench_scenario.mli)
- [Benchmark scenario implementation](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/bench_scenario/bonsai_bench_scenario.ml)
- [Incremental interface](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml)
- [`Bonsai_bench` API at the pinned package commit](https://github.com/janestreet/bonsai_bench/blob/0beb1b3dc308ad32dbd5c0a1429ceddfeb7b8d05/src/bonsai_bench.mli)

### Oxmono package sources

- [`Bonsai_bench` runner](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/bonsai_bench/src/runner.ml)
- [`Bonsai_bench` implementation](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/bonsai_bench/src/bonsai_bench.ml)
- [Official Bonsai benchmark guide snapshot](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/bonsai_web/docs/how_to/benchmarking.md)
- [Core_bench native sampler](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/core_bench/src/benchmark.ml)

## Validation record

- Read all existing files under `.scratch/research/eta-crux/`.
- Read all 1,078 lines of `lib/crux/bench/bench_eta_crux.ml`.
- Checked all three local checkout paths and Git identities.
- Compared Bonsai file hashes between the Bonsai and Oxmono checkouts.
- Read the production driver, scenario implementation, benchmark runner,
  benchmark guide, package records, and Core_bench sampler.
- Queried Eta's Nix shell for compiler, Dune, and installed package versions.
- Attempted a native Bonsai build with an external build directory.
- Made no benchmark implementation or source-code change.
