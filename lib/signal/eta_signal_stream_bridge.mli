(** Lossy stream observer bridge for Eta_signal. *)

val default_capacity : int

type metrics

val create_metrics : ?drop_count:int -> unit -> metrics
val drop_count : metrics -> int
val record_drop : metrics -> unit

val create_queue :
  capacity:int ->
  (('update, 'queue_error) Eta.Queue.t, [> `Invalid_capacity ]) result

type ('token, 'update, 'error) observer_delivery =
  ('token, 'update, unit -> unit) Eta_signal_observer.Delivery_handle.t

type ('queue_error, 'error) hooks

val hooks :
  metrics:metrics ->
  ?after_try_send_before_ack:(unit -> (unit, 'error) Eta.Effect.t) ->
  ?after_drop_before_ack:(unit -> (unit, 'error) Eta.Effect.t) ->
  ?after_drop_acknowledged:(unit -> unit) ->
  on_closed_with_error:('queue_error -> (unit, 'error) Eta.Effect.t) ->
  unit ->
  ('queue_error, 'error) hooks

val offer :
  queue:('update, 'queue_error) Eta.Queue.t ->
  observer_delivery:('token, 'update, 'error) observer_delivery ->
  hooks:('queue_error, 'error) hooks ->
  on_drop:('update -> unit) option ->
  (unit, 'error) Eta.Effect.t

val observe :
  capacity:int ->
  ?on_drop:('update -> unit) ->
  ?equal:('value -> 'value -> bool) ->
  metrics:metrics ->
  on_closed_with_error:
    (([> `Invalid_scope ] as 'queue_error) ->
    (unit, 'callback_error) Eta.Effect.t) ->
  map_observe_error:('observe_error -> ([> `Invalid_capacity ] as 'stream_error)) ->
  observe_delivery:
    (?equal:('value -> 'value -> bool) ->
     on_finish:
       (Eta_signal_observer.Lifecycle.finish_reason -> unit) list ->
     'signal ->
     (('token, 'update, 'callback_error) observer_delivery ->
      (unit, 'callback_error) Eta.Effect.t) ->
     ('observer, 'observe_error) Eta.Effect.t) ->
  'signal ->
  ( 'observer * ('update, 'queue_error) Eta_stream.Stream.t,
    'stream_error )
  Eta.Effect.t
