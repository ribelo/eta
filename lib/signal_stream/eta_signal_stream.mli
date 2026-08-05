exception Closed_with_invalid_scope
(** Defect raised when a bridge publication reaches a queue already closed by
    invalid scope. The graph lane and lifecycle finish hooks normally
    serialize close and publication, so this path requires an interrupted
    delivery. *)

type stream_error = [ Eta_signal.graph_error | `Invalid_capacity ]

module Make (Source : Eta_signal.Stream_source) : sig
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
      or lightweight logging. If the hook raises, Eta logs an
      [eta_signal.stream.on_drop_failure] defect through [Eta_observability],
      acknowledges the drop, and does not retry the hook.

      Each offered update gets exactly one sent-or-dropped outcome and one
      acknowledgement. Interruption cannot split that sequence.

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
