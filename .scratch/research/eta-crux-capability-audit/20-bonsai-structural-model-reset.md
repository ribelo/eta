# Bonsai structural model reset

## Scope

This report describes Bonsai behavior. It does not decide whether Eta Crux must adopt this capability.

The core source revision is Bonsai commit
[`f31661450eb133fe89564219d97669c2735c6622`](https://github.com/janestreet/bonsai/tree/f31661450eb133fe89564219d97669c2735c6622).
The test revision is Bonsai Test commit
[`6aac39071101dcd32c96564163cfcf66cc3b95bb`](https://github.com/janestreet/bonsai_test/tree/6aac39071101dcd32c96564163cfcf66cc3b95bb).

Two first-party example revisions have the same release identifier and timestamp as the core revision.
They supply use examples, not core semantic evidence.

- Bonsai Web:
  [`989c18b5381cad767365923d4f0b758c6f3c602c`](https://github.com/janestreet/bonsai_web/tree/989c18b5381cad767365923d4f0b758c6f3c602c)
- Bonsai Examples:
  [`1038b46e9d00fbeda3316a089f874857287e64b6`](https://github.com/janestreet/bonsai_examples/tree/1038b46e9d00fbeda3316a089f874857287e64b6)

## Summary

`with_model_resetter` adds one action constructor around a structural computation.
Its public reset authority is a `unit Effect.t`.
The effect injects the internal `Model_reset_outer` action.
The driver then processes this action in its normal action queue.
([constructor](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc_min.ml#L342-L345),
[gathering](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L28-L51),
[queue injection](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L63-L75))

Each gathered node has a synchronous `reset` function.
Composite nodes call the reset functions of their stored child models.
Leaf nodes use their optional custom reset function.
The default leaf reset returns `default_model`.
([internal reset type](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/computation.ml#L21-L35),
[default leaf reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc_min.ml#L95-L122))

This reset changes models.
It does not reconstruct the graph.
It does not replace action injectors.
It does not define general cancellation of effect work.
([reset action handling](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L28-L64),
[leaf injector construction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_leaf0.ml#L16-L27),
[in-flight effect test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_effect_throttling.ml#L58-L102))

`Bonsai_driver.Expert.reset_model_to_default` is different.
It writes the top-level initial model directly to the model variable.
Its interface says that it exists only for benchmarks.
([implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L384-L386),
[interface](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L68-L73))

## Public operations

### `with_model_resetter`

The continuation interface places the boundary around the `f` callback.
It says that all stateful components allocated in `f` receive reset calls.
Scheduling the returned effect starts these calls.
([public contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536))

The procedural interface gives the same operation a packed result.
It returns the inner result and the reset effect.
The procedural contract also states the default and custom leaf behavior.
([procedural contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc/proc_intf.ml#L636-L651))

`with_model_resetter'` puts the same reset effect inside the callback.
It does not define a different reset operation.
([continuation interface](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L548-L564),
[implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.ml#L969-L988))

The constructor creates a fresh `reset_id`.
It binds that identifier to a value with the `Model_resetter` value-kind.
The gathered computation later supplies the concrete effect.
([constructor](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc_min.ml#L342-L345),
[value kind](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/value.ml#L5-L13))

### Per-state `reset`

`state` accepts `reset : model -> model`.
Its documented default ignores the current model and returns the starting value.
([state contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L116-L138))

`state` adapts this function to the state-machine reset context.
`state'` uses the same adaptation.
([adapters](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc.ml#L487-L541))

`state_machine` and `state_machine_with_input` accept a richer reset function.
This function receives `Apply_action_context.t` and the current model.
The context supplies `inject`, `schedule_event`, and `time_source`.
([resetter type](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L184-L217),
[input state-machine signature](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L237-L260))

The implementation constructs the context from the leaf injector, event scheduler, and time source.
Without a custom function, it returns `default_model`.
([Leaf1 construction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc_min.ml#L95-L125),
[Leaf0 construction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc_min.ml#L134-L168))

The custom function can preserve the model.
It can also compute a non-default model.
A test doubles the current model on each reset.
Thus, reset is not necessarily idempotent.
([custom reset test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_cont_bonsai.ml#L5393-L5417))

The custom function can schedule an effect or inject a normal action.
Tests inject an action from reset and observe its later model value.
([Leaf0 test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L1933-L1963),
[Leaf1 test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L1966-L2001))

### Driver-wide reset

The driver stores `default_model` when it gathers the top-level computation.
It creates `model_var` with that value.
([driver creation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L119-L137))

`reset_model_to_default` only calls `Incr.Var.set model_var default_model`.
It does not enqueue `Model_reset_outer`.
It does not call custom leaf reset functions.
It does not schedule reset cleanup work.
([driver reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L368-L386))

The benchmark interaction maps `Reset_model` directly to this expert call.
A separate `Recompute` interaction flushes actions and triggers lifecycles.
Thus, benchmark reset does not itself request a recomputation.
([benchmark interaction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bench_scenario/bonsai_bench_scenario.ml#L48-L64),
[benchmark contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bench_scenario/bonsai_bench_scenario.mli#L41-L47))

## Reset authority and scheduling

The public authority is the returned `unit Effect.t`.
Internally, this effect is a lazy injection of the singleton `Model_reset_outer` action.
([public type](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536),
[effect binding](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L28-L37))

Normal child actions use `Model_reset_inner`.
This wrapper separates a reset request from actions for the wrapped computation.
([action constructors](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/action.mli#L15-L34),
[action type identifier](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/action.mli#L55-L70))

Effect handling enqueues the action.
`flush` dequeues actions in queue order.
It applies each action to the current aggregate model.
([effect handler](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L63-L75),
[flush loop](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L281-L337))

`Model_reset_outer` calls the inner structural reset function.
`Model_reset_inner` calls the normal inner action function.
([dispatch](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L48-L55))

A reset action is static for stabilization tracking.
A later dynamic child action requires stabilization if reset ran in the same generation.
([classification](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/stabilization_tracker.ml#L284-L297),
[reset rule](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/stabilization_tracker.ml#L310-L346))

A same-frame test resets a wrapper and then copies its inner result.
The copy sees the reset value.
([same-frame test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_action_stabilization.ml#L1192-L1250))

## Traversal boundary

The boundary starts at the computation passed to the resetter constructor.
Composition propagates one structural reset function through the gathered model shape.
([public boundary](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536),
[gather dispatch](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather.ml#L129-L160))

The following stateful model forms participate:

- `Leaf0` and `Leaf1` call their leaf reset functions.
  ([Leaf0](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_leaf0.ml#L29-L49),
  [Leaf1](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_leaf1.ml#L32-L52))
- `Sub` resets both stored models.
  ([Sub reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_sub.ml#L76-L94))
- `Wrap` resets its outer model and its inner model.
  ([Wrap reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_wrap.ml#L87-L108))
- `Switch` resets every model stored for every arm.
  ([Switch reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_switch.ml#L167-L207))
- `Assoc` resets every entry in its sparse keyed-model map.
  ([Assoc reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L143-L180))
- `Assoc_on` resets every entry in its model-key map.
  ([Assoc-on reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc_on.ml#L130-L181))
- Forced lazy and recursive nodes reset their stored model.
  An unforced node has no model and stays unforced.
  ([lazy reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_lazy.ml#L113-L152),
  [recursive reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_fix.ml#L165-L204))

Stateless inner computations receive an ignore effect.
The reset wrapper adds no model or action in this case.
([stateless fast path](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L12-L27))

### Nested resetters

Each nested resetter creates a fresh `reset_id`.
Therefore, each returned effect addresses its own structural node.
([fresh identifier](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc_min.ml#L342-L345))

An inner reset effect starts at the inner resetter.
It cannot address models outside that inner computation.
This follows from the action wrapper and local environment binding.
([local binding and action wrapper](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L28-L51))

An outer reset is not stopped by an inner resetter.
The inner resetter exposes a structural `reset` that delegates to its own inner reset.
Thus, an outer reset traverses through nested resetters.
([delegating reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L53-L64))

No public prose specifies this nested-boundary behavior.
The inspected reset tests do not contain a nested model-resetter case.
The behavior comes from the implementation.

## Dynamic branches and keyed children

### Switch branches

`Switch` initializes model storage for all arms.
Its reset maps over all stored arm models.
The selected arm does not limit reset traversal.
([initial storage](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_switch.ml#L193-L207),
[reset map](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_switch.ml#L167-L191))

A retained reset effect works while its resetter branch is inactive.
The test later activates the branch and observes its default model.
The retained state setter also updates the inactive branch model.
([inactive reset test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_cont_bonsai.ml#L5263-L5313))

An inactive and unforced lazy branch is different.
Its model is `None`, so reset does not force or descend into it.
Tests place an infinitely recursive lazy beside the active branch.
([lazy implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_lazy.ml#L137-L152),
[lazy test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L2060-L2087))

### `assoc`

`assoc` stores only non-default keyed models.
An action removes the key from model storage when the result equals the default.
([sparse storage](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L143-L165))

Reset traverses only entries present in that sparse storage.
It removes entries whose reset result equals the default.
It keeps non-default reset results.
([keyed reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L167-L180))

An active key at its default model has no stored model entry.
Its custom reset function therefore does not run.
The default reset has no observable difference for that key.
This behavior follows from the sparse implementation.
It is not stated in the public reset contract.
([default input merge](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L72-L80),
[keyed reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L167-L170))

Removed input keys do not automatically lose a stored non-default model.
The render merge omits a model-only key from current results.
The separate model map remains unchanged.
Reset still traverses that stored entry.
([input and model merge](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L72-L80),
[reset storage traversal](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L167-L170))

The test changes both keyed child models before reset.
It then observes two custom reset calls and two reset values.
([`assoc` test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L2120-L2158))

### `assoc_on`

`assoc_on` separates input keys from model keys.
Inputs with the same model key share one model.
([public contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1283-L1300))

Its reset traverses sparse storage by model key.
It preserves the last input key with each non-default result.
It removes a model-key entry when reset returns the default.
([implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc_on.ml#L154-L181))

## Injectors, lifecycles, and effect work

Reset changes the aggregate model in place.
The gathered computation and its action type stay the same.
Leaf injectors are built outside the model-dependent incremental map.
This placement keeps them physically equal across model changes.
([leaf injector comment and code](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_leaf0.ml#L16-L27),
[reset dispatch](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L48-L64))

A retained state setter can update an inactive branch.
A retained reset endpoint can reset that branch.
The inactive-branch test exercises both endpoints.
([inactive endpoint test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L1779-L1825))

Reset has no separate lifecycle phase.
Model changes can change the computed lifecycle collection during stabilization.
The driver later runs deactivations, activations, and after-display events in that order.
([main-loop and lifecycle contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L17-L37))

A reset does not automatically deactivate and reactivate an unchanged branch.
The core operation only calls model reset functions.
Lifecycle changes follow only from the new computation result and active structure.
([structural reset dispatch](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L48-L64),
[lifecycle observation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L352-L365))

Reset does not define general cancellation for running effects.
In the throttling test, a response for work started before reset still completes after reset.
([effect test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_effect_throttling.ml#L92-L102))

Individual state machines can implement reset-specific effect behavior.
The context lets them schedule cleanup or inject an action.
([context interface](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L184-L198),
[scheduled-action test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L1933-L1963))

## Atomicity, ordering, and failure

### Output observation

One reset action computes one complete aggregate model synchronously.
Composite reset functions return the complete tuple or map before the driver stores it.
([internal reset type](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/computation.ml#L21-L35),
[Sub reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_sub.ml#L86-L94))

The driver stores and stabilizes the model at a required barrier or after all queued actions.
The normal `result` call reads the stabilized result observer.
Thus, normal output reads do not observe cell-by-cell partial reset models.
([flush storage](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L300-L337),
[result](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L352-L352))

A custom reset can enqueue more actions.
The same `flush` can process these actions after the reset.
Therefore, the result after `flush` can include follow-up work, not only the direct reset result.
([queue loop](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L313-L337),
[scheduled-action result](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L1943-L1963))

The public interface does not state an atomicity law.
It also does not define observation through expert incremental observers during an internal stabilization.

### Cell order

The current implementation has concrete traversal orders:

- `Sub` resets `from` before `into`.
  ([order](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_sub.ml#L86-L93))
- `Wrap` resets the outer model before the inner model.
  ([order](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_wrap.ml#L87-L92))
- `Switch` uses `Map.mapi` over branch keys.
  ([order](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_switch.ml#L167-L191))
- `Assoc` and `Assoc_on` use `Map.filter_mapi` over stored keys.
  ([Assoc](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L167-L170),
  [Assoc-on](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc_on.ml#L154-L161))

No public contract specifies this order.
No inspected test asserts distinct reset order for multiple cells.
Consumers must not treat the current traversal order as a semantic law.

### Failure

The reset function type has no typed failure result.
It returns a model directly.
([reset type](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/computation.ml#L21-L25))

The driver does not catch exceptions around `apply_action`.
An exception from a custom reset escapes `flush`.
([action application](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L300-L325))

The driver stores the completed action result after `apply_action` returns.
Therefore, an exception prevents storage of that reset action result.
Effects scheduled before the exception can already have run or entered the queue.
([application and queue handling](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L313-L337))

The public interface gives no rollback rule.
It gives no order rule for scheduled effects.
The inspected tests do not cover a reset exception.

## Evidence classification

### Explicit public laws

The public interfaces explicitly state these semantics:

1. The resetter covers stateful components allocated inside its callback.
   Scheduling its effect invokes their reset functions.
   ([contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536))
2. A state reset defaults to the starting value.
   A custom reset function receives the current model.
   ([state contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L116-L138))
3. Stateful components default to `default_model`, unless their reset argument overrides this behavior.
   ([procedural contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc/proc_intf.ml#L636-L640))
4. The driver main loop flushes, reads the result, and then triggers lifecycles.
   Lifecycle order is deactivation, activation, and after-display.
   ([driver contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L17-L37))
5. Driver-wide reset exists only for benchmarking.
   It restores the initial top-level model.
   ([expert contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L68-L73))

### Behavior established by tests

The tests establish these additional behaviors for the tested revision:

1. A retained reset endpoint resets an inactive dynamic branch.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_cont_bonsai.ml#L5263-L5313))
2. A custom reset can return a non-default and non-idempotent model.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_cont_bonsai.ml#L5393-L5417))
3. A custom reset can schedule an injected action.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_cont_bonsai.ml#L5420-L5480))
4. A reset followed by a dependent dynamic action in one frame observes the reset model.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_action_stabilization.ml#L1192-L1250))
5. Reset reaches changed models in two active `assoc` children.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L2120-L2158))
6. Reset does not force an inactive, infinitely recursive lazy branch.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L2060-L2087))
7. Reset does not generally cancel already active throttled effect work.
   ([test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_effect_throttling.ml#L58-L102))

### Implementation-only behavior

The following points come from implementation structure:

- Outer reset traverses through a nested resetter.
  Inner reset authority stays inside its own boundary.
  ([implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L28-L64))
- `Switch` resets stored models for all arms, not only the active arm.
  ([implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_switch.ml#L167-L207))
- `Assoc` reset traverses sparse non-default keyed storage.
  ([implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L143-L180))
- Reset preserves graph structure and injector identity.
  ([implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_leaf0.ml#L16-L27))
- The current composite traversal has a deterministic implementation order.
  ([Sub](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_sub.ml#L86-L93),
  [Wrap](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_wrap.ml#L87-L92))

### Unspecified points

The inspected public interfaces do not specify these points:

- reset callback order across cells
- exception handling, rollback, or partial scheduled work
- formal atomicity for expert observers
- general effect cancellation
- lifecycle behavior beyond the normal driver lifecycle rules
- coalescing of repeated reset effects
- nested resetter precedence
- reset calls for active keyed children whose sparse model equals the default
- permanent validity of retained inactive action endpoints.

The implementation and tests give some current answers.
They do not make these answers public laws.

## First-party reasons for reset

### Scoped application reset

The first-party guide builds two counters inside one resetter.
A UI button schedules one effect to reset both counters.
([guide example](https://github.com/janestreet/bonsai_examples/blob/1038b46e9d00fbeda3316a089f874857287e64b6/bonsai_guide_code/state_reset_examples.ml#L6-L35))

The guide also places the reset effect inside the component.
This use supports a local reset button without exporting a separate control.
([internal-reset example](https://github.com/janestreet/bonsai_examples/blob/1038b46e9d00fbeda3316a089f874857287e64b6/bonsai_guide_code/state_reset_examples.ml#L37-L62))

`value_with_override` documents resetter use to remove an override.
The override then returns to its input value.
([component contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bonsai_kernel_components/value_utilities/bonsai_kernel_value_utilities.mli#L5-L16))

A first-party test uses reset on lifecycle deactivation.
It clears the state of a periodic reminder before the branch leaves.
([deactivation use](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_clock_remind_function.ml#L29-L47))

A memo test wraps a model-scoped memo table in a resetter.
It uses reset to clear memo state while lookup components remain outside the boundary.
([memo arrangement](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_memo_reset.ml#L4-L39),
[test purpose](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_memo_reset.ml#L94-L115))

The first-party reset guide gives two custom-reset reasons.
Tracked external status can ignore structural reset.
Externally open work can schedule cleanup before the model returns to empty.
([preserved status](https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/resetting_state.md#L126-L174),
[scheduled cleanup](https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/resetting_state.md#L296-L340))

The same guide warns that model reset does not automatically cancel external work.
The state machine must schedule that cleanup itself.
([warning and example](https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/resetting_state.md#L300-L335))

### Benchmark-only driver reset

The benchmark scenario uses driver-wide reset to restore the complete benchmark model.
This operation provides repeatable benchmark starting state.
It is not an application-scoped reset capability.
([benchmark interaction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bench_scenario/bonsai_bench_scenario.ml#L24-L64),
[expert restriction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L68-L73))

## Comparison with alternatives

### Explicit reset actions

An explicit reset action belongs to one state machine.
Its `apply_action` function decides the transition and any effects.
([state-machine contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L204-L224))

A structural reset action belongs to a graph boundary.
It calls the reset function of each stored stateful descendant.
The caller does not collect every child injector.
([resetter contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536),
[structural dispatch](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L48-L64))

A custom structural reset can bounce into an explicit action.
This pattern keeps one cell's transition logic in `apply_action`.
([bounce test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_proc_bonsai.ml#L1933-L1963))

Explicit actions give local action ordering and failure behavior.
They do not automatically discover all stateful descendants.
Structural reset gives discovery by graph shape.
Its public contract does not define callback order or rollback.
([state-machine contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L204-L224),
[resetter contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536))

### Keyed-incarnation replacement

A new `assoc` key reads `model_info.default` when no keyed model exists.
A removed key with stored non-default state keeps that state.
If the same key returns, Bonsai can use the retained model.
([merge behavior](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L72-L80),
[key action storage](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L143-L165))

Thus, removing and re-adding the same `assoc` key is not a reliable reset.
A genuinely new key selects a new default model slot.
This replacement changes keyed identity instead of traversing one existing subtree.
([keyed model lookup](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L72-L80))

`assoc_on` makes model identity explicit and separate from input identity.
Inputs can share a model key.
A changed model key selects its stored model or the default.
([public model-key contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1283-L1300),
[model lookup](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc_on.ml#L67-L80))

Keyed-incarnation replacement can isolate one keyed child.
Structural reset can affect many existing keyed children and non-keyed cells together.
The two mechanisms have different boundaries and identity effects.
([Assoc reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L167-L180),
[model-key contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1283-L1300))

## Audit conclusion

Bonsai structural reset is an action-routed traversal of stored model structure.
It is not graph reconstruction.
It is not a general effect-cancellation protocol.
([reset implementation](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_with_model_resetter.ml#L28-L64),
[effect test](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/of_bonsai_itself/test_effect_throttling.ml#L92-L102))

The public contract is broad.
The implementation boundary is the set of model values that composite storage can traverse.
Sparse keyed storage and unforced lazy storage narrow the practical callback set.
([public contract](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L536),
[sparse keyed reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_assoc.ml#L167-L170),
[unforced lazy reset](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_gather/gather_lazy.ml#L137-L142))

The driver-wide reset serves benchmark repeatability.
It must not be used as evidence for scoped application semantics.
([driver restriction](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L68-L73),
[benchmark use](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bench_scenario/bonsai_bench_scenario.ml#L48-L64))
