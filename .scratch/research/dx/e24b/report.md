# DX-E24b follow-up report — schedule hooks and deletion

## Revised verdict

**D wins as a deletion proposal.** A remains the correct ownership model only
while structural taps exist: schedule policy places hook values and drivers
interpret/resume them. That conditional architecture result does not establish
that Eta should keep the feature. There are zero production/example tap
producers, and the common “log every attempt” story has an ordinary operation
wrapper. The unique branch/phase-local capability is coherent but has no
demonstrated demand. The earlier word **permanent** is withdrawn.

This follow-up does not implement the cross-cutting deletion. It adds the exact
proposal in `review/DELETION_PROPOSAL.md` and makes the current custom-driver
contract truthful until that proposal lands.

## Complete inventory and candidate-D surface

- 8 hook-accepting external operations: Effect 3, Resource 1, Stream 4.
- 3 production interpreter helpers serving 3 + 1 + 4 operations.
- 2 explicit no-hook HTTP signatures; one public `no_hook` marker.
- 2 public tap constructors, one public `Hook` constructor, and 2 suspended
  stepping entry points (`step_plan`, `step_with_hooks`).
- 6 explicit public tap-behavior promises across Effect, Resource, and Stream.
- 12 pre-E24b tap constructions in 4 test files, all tests; 25 after the original
  and follow-up characterization laws. Zero production or example producers.
- `Eta_js` re-exports Schedule but has no separate hook implementation.

`redteam/d-surface.sh` asserts the deletion surface. D changes all eight
effectful signatures from three schedule parameters to two, removes the hook
protocol and three interpreters, and removes the `no_hook` marker from the two
HTTP signatures. This is meaningful surface reduction rather than a rename.

## Candidate-D capability and recipe assessment

| User story | Ordinary-code recipe after D | Rating | Lost capability |
| --- | --- | --- | --- |
| Log every Effect retry/repeat attempt | Instrument the source effect | 4/5 | Schedule output/phase hooks |
| Observe `Resource.auto` refreshes | Instrument `load`; application counter distinguishes seed/refresh | 2/5 | Terminal schedule step and a clean schedule-only boundary |
| Observe Stream retry/schedule | Put `Stream.tap_error` on the source before retry, instrument the source, or use `Stream.tap` | 2/5 | Terminal non-emitted input/output and empty-repeat boundaries |
| Observe a custom driver | Log around direct `Schedule.step` | 4/5 top-level | Branch/phase-local events inside one composed step |
| Preserve exact structural taps | No ordinary recipe | 0/5 | The feature is deliberately deleted |

The named integration `retry attempts can be observed without schedule taps`
executes the real Effect recipe. `redteam/d_recipe.ml` executes the equivalent
custom-driver recipe; its negative control confirms that the left terminal and
right-entry events within one `and_then` step are unavailable. Resource/Stream
recipes remain explicitly partial guidance, not parity fixtures in this packet.

The demand finding is direct: no shipped package, example, or non-test code
constructs a tap. Public signatures and tests prove behavior, not demand. D
would be reversed before implementation by a shipped producer, concrete external
adoption requiring schedule-local placement, or an observability integration
that cannot use operation-level instrumentation. None exists in-repository.

## Complete suspension and observability matrix

“Tap inside wrapper” means `wrapper (tap base)`; “tap outside” means
`tap (wrapper base)`.

| Row | A — current policy hooks | B — driver observers | C — tested seam variants | D — delete |
| --- | --- | --- | --- | --- |
| Pre-step | Branch/phase-local `tap_input`, possibly several per public step | Top-level driver observers see only the outer call; structural observers require policy-owned placement | Retained only by an A-shaped plan | No schedule pre-step event; instrument the process |
| Post-step / `Done` | `tap_output` sees every local output, including terminal `Done` | Top-level driver observers see only the outer decision; structural observers require policy-owned placement | Tested variants retain/bundle the plan or lose the interpreter boundary | Continuing emitted/process results only via ordinary wrappers |
| Composition | Deterministic structural order, including `and_then` handoff | Top-level observers cannot represent branch/phase-local placement; structural observers can only by restoring policy-owned placement | The tested variants fail the existential boundary or add packaging surface | Structural event capability intentionally absent |
| Resume success | Interpret hook, then invoke continuation exactly once | A new structural protocol would need the same rule | Bundled interpreter can enforce its own rule | No resume closure |
| Abandonment | Abandoning a `Hook` publishes nothing and leaves the original driver reusable | Driver-specific callbacks need an explicit publication rule | Same issue if suspension is retained | Not applicable |
| Multiple resume | Public closure is non-linear and can be invoked repeatedly; this duplicates tentative evaluation, so the custom-driver contract forbids it | No analogue for top-level callbacks; structural callbacks would need a one-shot rule | Tested package does not make the closure linear | Not applicable |
| Interpretation/resume failure | No `Complete`, decision, or next driver is returned; retain original driver | All eight APIs would need equivalent semantics, possibly via a shared helper | Same if plan retained | No hook failure boundary |
| Partial effects and retry | Earlier successful hook effects are not rolled back; retrying the original driver repeats them | Same burden for any multi-observer protocol | Same if plan retained | Ordinary process effects follow their own operation semantics |
| Cancellation | Custom contract says abandon without resume. Effect integration proves interruption is preserved; Resource/Stream use effect binds but lack cancellation-specific tap tests | Owned by each driver observer protocol | Owned by packaged interpreter | No hook interpretation to cancel |
| Tap failure asymmetry | `tap_input` failure occurs before inner evaluation; `tap_output` failure occurs after tentative output computation but before publication, so retry recomputes | Top-level before/after callbacks have a coarser analogue only | Retained only with suspended placement | No tap asymmetry |
| `modify_delay` / `while_output` | On tested `Continue` paths when the callback runs, `tap_input` is before it regardless of placement; `tap_output` inside is before it and outside is after | Top-level observer sees only post-wrapper decision | Tested seam adds no different ordering model | No interaction |
| `jittered` | On tested `Continue` paths when a draw runs, `tap_input` is before it regardless of placement; `tap_output` inside is before it and outside is after | Top-level observer sees jittered decision only | Tested seam adds no different ordering model | No interaction |
| `named` | Changes `pp` only; stepping and hook order are identical | No defined relationship | No change in tested packages | Surviving schedule label remains a display concern |
| Telemetry | Stepping and `Schedule.named` emit no automatic spans/logs/metrics. Hook effects may emit their own; their emitted telemetry was not separately compared named vs plain | A driver callback may emit its own telemetry | A packaged interpreter may emit its own | Operation wrappers emit application-owned telemetry |
| No-hook ergonomics | `no_hook` gives direct `step`/`next` and rejects tapped direct stepping | Binary schedules but observer contracts move to drivers | Tested variants do not remove the core protocol cleanly | Every schedule is directly step-able; marker disappears |

Executable evidence:

- the renamed fixed-shape ownership table runs all six interpreter-failure
  positions for each of 50 generated payloads and records retained partial
  effects plus full replay;
- the suspension table proves double invocation, failure replay, continuation
  exceptions, and input/output failure asymmetry; the existing `tap_input`
  property proves raw plan abandonment leaves the original driver unchanged;
- the wrapper table proves inside/outside order for `modify_delay`,
  `while_output`, and `jittered`, plus `named` stepping/telemetry transparency;
- the existing Effect integration `schedule tap interruption is preserved`
  covers real cancellation at the shared Effect interpreter.

## E22 reckoning

The current protocol remains public until D is implemented, so its operational
prose is law-bearing. E22 now records 117 direct mli claims, 102 external claim
clusters, and 66 unique qcheck properties. Schedule has 24 direct claims and 4
external rows. M97–M112 cover continuation discipline, failure publication,
partial-effect replay, `tap_output` recomputation, and `named`; R102 registers
actual Effect cancellation. The two new properties are explicitly strong
fixed-shape tables with generated payload/seed variance, not generated-shape
laws.

## Surface and footgun deltas

| Metric | Before follow-up | Current contract | D proposal |
| --- | ---: | ---: | ---: |
| `Schedule.t` parameters | 3 | 3 | 2 |
| Public tap vals | 2 | 2 | 0 |
| Public suspended constructors | 1 `Hook` | 1 `Hook` | 0 |
| Suspended stepping entry points | 2 | 2 | 0 |
| Hook-accepting external operations | 8 | 8 | 0 |
| Production interpreters | 3 | 3 | 0 |
| Direct Schedule qcheck claims | 8 | 24 | deleted with feature |
| Unique qcheck properties | 64 | 66 | deletion follow-up decides replacements |

The current change removes the undocumented custom-driver footguns around
non-linear resume, publication, partial effects, cancellation, and tap failure
asymmetry. D then removes the protocol rather than retaining those footguns.

## Cross-tab and final statuses

| Candidate | Strongest positive | Strongest counterevidence | Final status |
| --- | --- | --- | --- |
| A — policy hooks | Only tested model with exact structural composition and arbitrary driver interpretation | Zero production/example demand | **CONDITIONAL: correct while feature exists** |
| B — driver observers | Simple operation-local attempt callbacks | Top-level observers cannot match structural placement; restoring placement recreates policy ownership | **REJECTED as tap parity; ordinary recipes retained** |
| C — seam redesign | Correctly focuses on interpretation boundary | Tested variants fail or add surface; broader C family remains untested | **TESTED VARIANTS REJECTED, not universally dominated** |
| D — delete | Largest real surface reduction; common attempt recipe works | Exact structural observation becomes inexpressible | **ACCEPTED AS FOLLOW-UP PROPOSAL** |

The decisive criterion is demonstrated demand, not migration cost: repository
policy permits public surface only for behavior users actually need. Current
evidence proves the feature is coherent but does not prove a user.

## Prediction scoring after expanding the hypothesis space

The sealed prediction omitted the method's canonical deletion candidate. Its A
prediction remains a hit about ownership *conditional on retention*, but the
“A lands permanently” conclusion is a miss once D is admitted. B's structural
parity failure, the tested C results, E22 gap, producer/consumer split, and
corrected 12/4 census remain hits. The important follow-up result is that a
locally accurate A/B/C comparison did not answer the complete product question.

## Verification

```text
.scratch/research/dx/e24b/redteam/run-all.sh
PASS — includes D surface and recipe probes; 12 baseline / 25 current taps

nix develop -c dune runtest test/laws --force
PASS — 66 properties, 50 generated cases per fixed-shape table

nix develop -c dune runtest test/core_eio --force
PASS — 571 tests, including both tap interruption placements and actual no-tap
Effect retry recipe

nix develop -c dune build @install
PASS

nix develop -c dune runtest --force
PASS

nix develop -c eta-oxcaml-test-shipped
PASS

nix develop .#mainline -c dune build --build-dir=_build-mainline @install
PASS — OCaml 5.4.1

nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
PASS — 66 properties

nix develop -c dune build @doc
PASS — existing unrelated odoc warnings remain
```

Independent review found and closed missing output-cancellation coverage,
coarse E22 claim clustering, incomplete deletion internals/`next`, overbroad
wrapper/telemetry wording, and recipe overreach. Its final verdict was
**CONTENT READY** with the registry at 117 direct / 102 external / 219 covered.

## Shipped state and follow-up

Runtime behavior is unchanged in this commit. The interface, laws, E22 registry,
decision packet, and journal agree on the current driver contract. The deletion
proposal is exact but intentionally separate; implementing it is the next
cross-cutting production change, with no compatibility shim.
