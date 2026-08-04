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
    (('output frame, operation_error) result, Eta_crux.never)
    Eta.Effect.t

  val drain :
    ('output, 'incoming) t ->
    max_steps:int ->
    (('output drain, operation_error) result, Eta_crux.never)
    Eta.Effect.t

  val stop :
    ('output, 'incoming) t ->
    ((Eta_crux.Driver.terminal, operation_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val poll :
    ('output, 'incoming) t ->
    (('output Eta_crux.Driver.event option, operation_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val await :
    ('output, 'incoming) t ->
    (('output Eta_crux.Driver.event, operation_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val delivery_delivered :
    ('output, 'incoming) t ->
    'output Eta_crux.Driver.Delivery.t ->
    ((unit, Eta_crux.Driver.Delivery.completion_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val delivery_failed :
    ('output, 'incoming) t ->
    'output Eta_crux.Driver.Delivery.t ->
    Eta_crux.Failure.Packed_cause.t ->
    ((unit, Eta_crux.Driver.Delivery.completion_error) result,
     Eta_crux.never)
    Eta.Effect.t

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
    (('spec, 'item, 'error) incarnation, Eta_crux.never)
    Eta.Effect.t

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

module Recording_adapter : sig
  type 'output event =
    | Acquire
    | Deliver of 'output Eta_crux.Adapter.delivery
    | Request_event of Eta_crux.Request.Driver_event.t
    | Crash_detected of Eta_crux.Failure.t
    | Release

  type ('output, 'error) t

  val create :
    pp_error:(Format.formatter -> 'error -> unit) ->
    ('output, 'error) t

  val resource :
    ('output, 'error) t ->
    ('output, 'error) Eta_crux.Adapter.resource

  val acquire_control :
    ('output, 'error) t ->
    (unit, unit, 'error) Eta_test.Controlled.t

  val release_control :
    ('output, 'error) t ->
    (unit, unit, 'error) Eta_test.Controlled.t

  val delivery_control :
    ('output, 'error) t ->
    ('output Eta_crux.Adapter.delivery, unit, 'error)
    Eta_test.Controlled.t

  val request_control :
    ('output, 'error) t ->
    (Eta_crux.Request.Driver_event.t, unit, 'error)
    Eta_test.Controlled.t

  val crash_control :
    ('output, 'error) t ->
    (Eta_crux.Failure.t, unit, 'error) Eta_test.Controlled.t

  val events : ('output, 'error) t -> 'output event list
end
