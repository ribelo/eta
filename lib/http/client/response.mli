(** Public eta-http response model. *)

type t = {
  status : int;
  headers : Header.t;
  body : Stream.t;
  trailers : (unit -> (Header.t, Error.t) Eta.Effect.t);
}

val make :
  ?headers:Header.t ->
  ?trailers:(unit -> (Header.t, Error.t) Eta.Effect.t) ->
  status:int ->
  body:Stream.t ->
  unit ->
  t
