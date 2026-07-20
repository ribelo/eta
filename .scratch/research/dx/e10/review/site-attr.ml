(* Same site as site-handwritten.ml, spelled with [@@eta.trace]. *)
open Eta

let program () = Effect.pure () [@@eta.trace]
