(** Queue/drop policy for Eta_signal stream bridges. *)

val default_capacity : int

val create_queue :
  capacity:int ->
  (('update, 'queue_error) Eta.Queue.t, [> `Invalid_capacity ]) result

val offer :
  queue:('update, 'queue_error) Eta.Queue.t ->
  current_token:(unit -> ('token option, 'error) Eta.Effect.t) ->
  acknowledge_sent:('token -> 'update -> (unit, 'error) Eta.Effect.t) ->
  acknowledge_drop:('token -> 'update -> (unit, 'error) Eta.Effect.t) ->
  after_try_send_before_ack:(unit -> (unit, 'error) Eta.Effect.t) ->
  after_drop_before_ack:(unit -> (unit, 'error) Eta.Effect.t) ->
  on_closed_with_error:('queue_error -> (unit, 'error) Eta.Effect.t) ->
  on_drop:('update -> unit) option ->
  'update ->
  (unit, 'error) Eta.Effect.t
