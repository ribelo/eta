(** Queue/drop policy for Eta_signal stream bridges. *)

val default_capacity : int

val create_queue :
  capacity:int ->
  (('update, 'queue_error) Eta.Queue.t, [> `Invalid_capacity ]) result

val create_stream :
  capacity:int ->
  ( ('update, 'queue_error) Eta.Queue.t
    * ('update, 'queue_error) Eta_stream.Stream.t,
    [> `Invalid_capacity ] )
  result

type ('token, 'update, 'error) delivery = {
  current_token : unit -> ('token option, 'error) Eta.Effect.t;
  acknowledge_sent : 'token -> 'update -> (unit, 'error) Eta.Effect.t;
  acknowledge_drop : 'token -> 'update -> (unit, 'error) Eta.Effect.t;
}

type ('token, 'update, 'error) observer_delivery = {
  observer_update : 'update;
  observer_current_token : unit -> ('token option, 'error) Eta.Effect.t;
  observer_acknowledge_sent :
    'token -> 'update -> (unit, 'error) Eta.Effect.t;
  observer_acknowledge_drop :
    'token -> 'update -> (unit, 'error) Eta.Effect.t;
}

type ('queue_error, 'error) hooks = {
  after_try_send_before_ack : unit -> (unit, 'error) Eta.Effect.t;
  after_drop_before_ack : unit -> (unit, 'error) Eta.Effect.t;
  on_closed_with_error : 'queue_error -> (unit, 'error) Eta.Effect.t;
}

type ('finish_reason, 'queue_error) finish_policy = {
  is_invalid_scope : 'finish_reason -> bool;
  invalid_scope_error : 'queue_error;
}

val finish_hook :
  queue:('update, 'queue_error) Eta.Queue.t ->
  policy:('finish_reason, 'queue_error) finish_policy ->
  'finish_reason ->
  unit

val observer_finish_hook :
  queue:('update, [> `Invalid_scope ]) Eta.Queue.t ->
  Eta_signal_observer.Lifecycle.finish_reason ->
  unit

val offer :
  queue:('update, 'queue_error) Eta.Queue.t ->
  delivery:('token, 'update, 'error) delivery ->
  hooks:('queue_error, 'error) hooks ->
  on_drop:('update -> unit) option ->
  'update ->
  (unit, 'error) Eta.Effect.t

val offer_observer_delivery :
  queue:('update, 'queue_error) Eta.Queue.t ->
  observer_delivery:('token, 'update, 'error) observer_delivery ->
  hooks:('queue_error, 'error) hooks ->
  on_drop:('update -> unit) option ->
  (unit, 'error) Eta.Effect.t
