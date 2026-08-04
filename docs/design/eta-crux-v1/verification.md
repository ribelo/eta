# Eta Crux V1 verification

## Required test surfaces

Every law in [Semantic laws](semantic-laws.md) names its executable gate. The
implementation is not complete until all named gates exist and pass.

The test tree has these groups:

```text
test/crux/unit/          focused deterministic cases
test/crux/laws/          generated bounded laws
test/crux/races/         private two-winner race gates
test/crux/conformance/   identity and serialized shared scenarios
test/crux/wire/          frame matrices and malformed input
test/crux/telemetry/     fixed observation contract
lib/crux/bench/          production benchmark executable
```

Private race barriers can stop a contender before a real linearization point.
No barrier callback can run while the root lock is held. Race hooks are not
part of `eta_crux_test`.

## Public test API

```ocaml
module Eta_crux_test : sig
  module Incoming : sig
    type ('output, 'incoming) t

    val create :
      send:
        ('output ->
         'incoming ->
         (unit, Eta_crux.Endpoint.admission_error) Eta.Effect.t) ->
      ('output, 'incoming) t

    val none : ('output, Eta_crux.never) t
  end

  module Test_shell : sig
    type ('output, 'error) t = {
      pp_error : Format.formatter -> 'error -> unit;
      deliver :
        'output Eta_crux.Adapter.delivery ->
        (unit, 'error) Eta.Effect.t;
      request_event :
        Eta_crux.Request.Driver_event.t ->
        (unit, 'error) Eta.Effect.t;
      crash_detected :
        Eta_crux.Failure.t ->
        (unit, 'error) Eta.Effect.t;
    }
  end

  module Handle : sig
    type ('output, 'incoming) t
    type operation_error = Busy
    type inject_error = No_output | Ingress_closed

    type 'output frame_outcome =
      | Idle
      | Rejected of Eta_crux.Root.delivery_error
      | Committed of 'output
      | Stopped
      | Crashed of Eta_crux.Failure.settlement

    type 'output frame = {
      outcome : 'output frame_outcome;
      events : 'output Eta_crux.Driver.event list;
    }

    type drain_status =
      | Idle
      | Limit_reached
      | Closed of Eta_crux.Driver.terminal

    type 'output drain = {
      status : drain_status;
      events : 'output Eta_crux.Driver.event list;
    }

    val create :
      incoming:('output, 'incoming) Incoming.t ->
      shell:('output, 'shell_error) Test_shell.t ->
      'output Eta_crux.Root.t ->
      ('output, 'incoming) t

    val use :
      incoming:('output, 'incoming) Incoming.t ->
      shell:('output, 'shell_error) Test_shell.t ->
      'output Eta_crux.Root.t ->
      f:
        (('output, 'incoming) t ->
         ('result, 'body_error) Eta.Effect.t) ->
      ('result, 'body_error) Eta.Effect.t

    val last_output : ('output, 'incoming) t -> 'output option

    val inject :
      ('output, 'incoming) t ->
      'incoming ->
      (unit, inject_error) Eta.Effect.t

    val frame :
      ('output, 'incoming) t ->
      (('output frame, operation_error) result, Eta_crux.never) Eta.Effect.t

    val drain :
      ('output, 'incoming) t ->
      max_steps:int ->
      (('output drain, operation_error) result, Eta_crux.never) Eta.Effect.t

    val stop :
      ('output, 'incoming) t ->
      ((Eta_crux.Driver.terminal, operation_error) result, Eta_crux.never)
        Eta.Effect.t

    val poll :
      ('output, 'incoming) t ->
      (('output Eta_crux.Driver.event option, operation_error) result,
       Eta_crux.never) Eta.Effect.t

    val await :
      ('output, 'incoming) t ->
      (('output Eta_crux.Driver.event, operation_error) result,
       Eta_crux.never) Eta.Effect.t

    val delivery_delivered :
      ('output, 'incoming) t ->
      'output Eta_crux.Driver.Delivery.t ->
      ((unit, Eta_crux.Driver.Delivery.completion_error) result,
       Eta_crux.never) Eta.Effect.t

    val delivery_failed :
      ('output, 'incoming) t ->
      'output Eta_crux.Driver.Delivery.t ->
      Eta_crux.Failure.Packed_cause.t ->
      ((unit, Eta_crux.Driver.Delivery.completion_error) result,
       Eta_crux.never) Eta.Effect.t

    val request_stop : ('output, 'incoming) t -> unit
  end

  module Controlled_source : sig
    type ('spec, 'item, 'error) t
    type ('spec, 'item, 'error) incarnation

    type state =
      | Opening
      | Running
      | Completed
      | Failed
      | Cancelled

    type control_error = Wrong_state of state

    type emit_error =
      | Control of control_error
      | Admission of Eta_crux.Endpoint.admission_error

    val create : unit -> ('spec, 'item, 'error) t

    val producer :
      ('spec, 'item, 'error) t ->
      'spec ->
      ('item, 'error) Eta_crux.Source.producer

    val poll_incarnation :
      ('spec, 'item, 'error) t ->
      ('spec, 'item, 'error) incarnation option

    val await_incarnation :
      ('spec, 'item, 'error) t ->
      (('spec, 'item, 'error) incarnation, Eta_crux.never) Eta.Effect.t

    val spec : ('spec, 'item, 'error) incarnation -> 'spec
    val state : ('spec, 'item, 'error) incarnation -> state

    val open_ :
      ('spec, 'item, 'error) incarnation ->
      (unit, control_error) result

    val fail_open :
      ('spec, 'item, 'error) incarnation ->
      'error ->
      (unit, control_error) result

    val emit :
      ('spec, 'item, 'error) incarnation ->
      'item ->
      (unit, emit_error) Eta.Effect.t

    val complete :
      ('spec, 'item, 'error) incarnation ->
      (unit, control_error) result

    val fail :
      ('spec, 'item, 'error) incarnation ->
      'error ->
      (unit, control_error) result

    val captured_emitter :
      ('spec, 'item, 'error) incarnation ->
      'item Eta_crux.Source.emit option

    val expect_no_pending : ('spec, 'item, 'error) t -> unit
  end
end
```

The package also exports a recording `Adapter.resource`. General controlled
effects belong to `Eta_test.Controlled`, not `eta_crux_test`.

## Operational telemetry

The fixed logs are:

| Body | Level |
|---|---|
| `eta_crux.root.started` | `Info` |
| `eta_crux.root.stopped` | `Info` |
| `eta_crux.root.crashed` | `Error` |

The crash log can contain `eta_crux.failure.origin`,
`eta_crux.failure.trigger`, and `eta_crux.observation.position`.

The fixed metrics are:

| Name | Kind | Unit | Attributes |
|---|---|---|---|
| `eta_crux.advancements.total` | counter | `{advancement}` | `eta_crux.trigger`, `eta_crux.outcome` |
| `eta_crux.advancement.duration` | histogram | `ms` | `eta_crux.trigger`, `eta_crux.outcome` |
| `eta_crux.roots.terminal.total` | counter | `{root}` | `eta_crux.outcome` |

The duration boundaries are `0.01`, `0.025`, `0.05`, `0.1`, `0.25`, `0.5`,
`1`, `2.5`, `5`, `10`, `25`, `50`, `100`, `250`, `500`, and `1000`
milliseconds.

The fixed spans are:

- `eta_crux.advance`
- `eta_crux.post_commit`
- `eta_crux.driver.delivery`
- `eta_crux.driver.request`
- `eta_crux.session.replace`
- `eta_crux.root.teardown`

Telemetry contains no application payload or runtime identity. Idle polls and
driver waits create no telemetry.

## Performance gates

Performance compares fresh baseline and candidate runs in the same environment.
OxCaml and upstream OCaml use separate baselines. Generated measurements remain
local and checked-in numbers never control a gate.

Use these commands:

```sh
nix develop -c bash bench/run.sh --quick --filter '^eta_crux\.'
nix develop -c bash bench/run.sh --filter '^eta_crux\.'
nix develop .#mainline -c bash bench/run.sh --quick --filter '^eta_crux\.'
nix develop .#mainline -c bash bench/run.sh --filter '^eta_crux\.'
```

A full row uses five warm-up samples and 31 measured samples. Each measured
sample lasts at least 50 ms. Reports include the mean, standard deviation,
median, p95, allocation classes, deterministic counters, environment, revision,
and dirty state.

A wall-time row fails when its median increases by more than 15% in two of three
complete comparisons. An allocation row fails when allocated words increase by
more than 5% and by more than one word per operation.

The suite contains these rows:

1. One complete admitted action.
2. One equal-model action with dependent-projection counters.
3. One changed keyed child at 10,000 and 100,000 children.
4. One persistent-output reconciliation at 10,000 and 100,000 rows.
5. One removal with blocked cleanup and overlapping new work.
6. One common identity-binding scenario.
7. The same serialized scenario with 0 B, 64 B, and 4 KiB payloads.
8. One disabled-telemetry advancement and its absent-telemetry control.
9. Capacity saturation and churn at 1, 64, and 1,024 entries.

Setup is outside each measured operation. Deterministic counters fail on their
first violation. The identity row requires zero wire operations. Disabled
telemetry requires equal allocation and at most 5% extra median time.

Ingress entries never exceed ingress capacity. Pending requests never exceed
request capacity. Serialized handles never exceed live serialized exports.
After session replacement and a full major collection, no old-session handle or
removed export remains.
