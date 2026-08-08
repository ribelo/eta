exception Closed_with_invalid_scope
(** Defect raised when a bridge publication reaches a queue already closed by
    invalid scope. The delivery phase and lifecycle finish hooks normally
    serialize close and publication, so this path requires an interrupted
    delivery. *)

type stream_error = [ Eta_signal.graph_error | `Invalid_capacity ]

module type Source = sig
  type 'a signal
  type 'a observer
  type observer_error

  type 'a update =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  module Observer : sig
    type 'a t = 'a observer

    val observe :
      ?cutoff:'a Eta_signal.Cutoff.t ->
      ?on_finish:([ `Disposed | `Invalid_scope ] -> unit) ->
      ?on_update:('a update -> (unit, observer_error) result) ->
      'a signal ->
      ('a t, Eta_signal.graph_error) result

    val dispose : 'a t -> (unit, Eta_signal.graph_error) result
  end
end
(** The synchronous observer seam a Signal instance satisfies in full. The
    bridge registers an ordinary observer whose callback offers the update to
    a bounded queue without blocking; the acknowledgement is the callback's
    normal return. There is no delivery handle, cursor, or token to leak. *)

module Make (Source : Source) : sig
  type 'a signal = 'a Source.signal
  type 'a observer = 'a Source.observer
  type 'a update = 'a Source.update
  type 'a stream = ('a update, [ `Invalid_scope ]) Eta_stream.Stream.t

  val default_capacity : int

  val observe :
    ?capacity:int ->
    ?on_drop:('a update -> unit) ->
    ?cutoff:'a Eta_signal.Cutoff.t ->
    'a signal ->
    ('a observer * 'a stream, stream_error) Eta.Effect.t
  (** [observe ?capacity signal] creates an observer and a stream of observer
      updates. [capacity] defaults to {!default_capacity} and bounds the
      bridge queue. Without [?cutoff], stream update emission uses
      {!Eta_signal.Cutoff.phys_equal} as its observer cutoff. Pass [?cutoff]
      when stream consumers must receive updates only for structural value
      changes.

      Publication from stabilization is nonblocking: when the bridge already
      has [capacity] buffered updates, the newest stream update is dropped and
      stabilization continues. A later delivered change may therefore report
      an [old_value] that was not itself delivered through the stream. Pass
      [?on_drop] to observe each dropped update; the hook runs synchronously
      during observer delivery and should be reserved for counters, metrics,
      or lightweight logging. If the hook raises, the drop is acknowledged
      and the hook is not retried.

      Delivery is synchronous and cannot interpret observability effects, so
      hook and publication defects are buffered and logged through
      [Eta_observability] the next time an effectful bridge [observe] or
      [with_observed] call runs: [eta_signal.stream.on_drop_failure] for a
      raising [on_drop] hook, [eta_signal.stream.offer_failure] for a
      publication defect. A publication defect is acknowledged without
      retry: the queue commits a send before waking consumers, so retrying
      could duplicate an update that is already visible.

      Each offered update gets exactly one sent-or-dropped outcome and one
      acknowledgement. The synchronous delivery phase cannot split that
      sequence.

      Disposal closes the stream after buffered updates drain. Invalid scope
      closes the stream with [`Invalid_scope]. The stream can cross domains;
      the observer handle and graph operations remain owner-domain-only. *)

  val with_observed :
    ?capacity:int ->
    ?on_drop:('a update -> unit) ->
    ?cutoff:'a Eta_signal.Cutoff.t ->
    'a signal ->
    ('a stream -> ('b, 'err) Eta.Effect.t) ->
    ('b, [> stream_error ] as 'err) Eta.Effect.t
  (** [with_observed signal f] observes [signal], runs [f] with the stream,
      and disposes the observer exactly once on every exit. *)
end
