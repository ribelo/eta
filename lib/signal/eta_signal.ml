include Eta_signal_kernel

type graph_error = Eta_signal_error.graph_error

module type Stream_source = sig
  type 'a signal
  type 'a observer
  type 'a update
  type 'a delivery
  type observer_error
  type observer_finish = [ `Disposed | `Invalid_scope ]

  val observe_delivery :
    ?cutoff:'a Cutoff.t ->
    ?on_finish:(observer_finish -> unit) ->
    'a signal ->
    ('a delivery -> (unit, observer_error) Eta.Effect.t) ->
    ('a observer, graph_error) Eta.Effect.t

  val current : 'a delivery -> ('a update option, 'error) Eta.Effect.t
  val acknowledge : 'a delivery -> (unit, 'error) Eta.Effect.t
  val dispose : 'a observer -> (unit, graph_error) Eta.Effect.t
end
