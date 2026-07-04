(** Queue/drop policy for Eta_signal stream bridges. *)

val default_capacity : int

val create_queue :
  capacity:int ->
  (('update, 'queue_error) Eta.Queue.t, [> `Invalid_capacity ]) result

type ('token, 'update, 'error) delivery = {
  current_token : unit -> ('token option, 'error) Eta.Effect.t;
  acknowledge_sent : 'token -> 'update -> (unit, 'error) Eta.Effect.t;
  acknowledge_drop : 'token -> 'update -> (unit, 'error) Eta.Effect.t;
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

val offer :
  queue:('update, 'queue_error) Eta.Queue.t ->
  delivery:('token, 'update, 'error) delivery ->
  hooks:('queue_error, 'error) hooks ->
  on_drop:('update -> unit) option ->
  'update ->
  (unit, 'error) Eta.Effect.t
