exception Closed_with_invalid_scope =
  Eta_signal_stream_bridge.Closed_with_invalid_scope

type stream_error = [ Eta_signal.graph_error | `Invalid_capacity ]

module Make (Source : Eta_signal.Stream_source) = struct
  module Bridge = Eta_signal_stream_bridge.Make (Source)

  type 'a signal = 'a Source.signal
  type 'a observer = 'a Source.observer
  type 'a update = 'a Source.update
  type 'a stream = ('a update, [ `Invalid_scope ]) Eta_stream.Stream.t

  let default_capacity = Bridge.default_capacity
  let observe = Bridge.observe

  let with_observed :
        type a b.
        ?capacity:int ->
        ?on_drop:(a update -> unit) ->
        ?cutoff:a Eta_signal.Cutoff.t ->
        a signal ->
        (a stream -> (b, [> stream_error ]) Eta.Effect.t) ->
        (b, [> stream_error ]) Eta.Effect.t =
   fun ?capacity ?on_drop ?cutoff signal f ->
    Eta.Effect.with_resource
      ~acquire:
        (observe ?capacity ?on_drop ?cutoff signal
         |> Eta.Effect.map_error (fun e -> (e : stream_error :> [> stream_error ])))
      ~release:(fun (observer, _stream) -> Source.dispose observer)
      (fun (_observer, stream) -> f stream)
end
