(* Predicted error: the stream may fail with `Boom, but the ascribed program
   only admits `Other.

   Property defended: S-B keeps the stream error channel unified with the
   Effect error row and does not erase typed failures at Stream.run. *)

let bad_stream : (< >, [ `Boom ], int) S_b_stream_core.Stream.t =
  S_b_stream_core.Stream.fail `Boom

let _bad_program :
    (< >, [ `Other ], int) S_b_stream_core.Effect.t =
  S_b_stream_core.run bad_stream
    (S_b_stream_core.Sink.fold ( + ) 0)
