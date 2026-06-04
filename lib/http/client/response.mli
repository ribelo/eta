(** Public eta-http response model. *)

type t = {
  status : int;
  headers : Header.t;
  body : Stream.t;
  trailers : (unit -> (Header.t, Error.t) Eta.Effect.t) @@ many;
}

val make :
  ?headers:Header.t ->
  ?trailers:(unit -> (Header.t, Error.t) Eta.Effect.t) @ many ->
  status:int ->
  body:Stream.t ->
  unit ->
  t
