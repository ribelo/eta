(** Public eta-http response model. *)

type t = {
  status : int;
  headers : Http_core.Header.t;
  body : Http_body.Stream.t;
  trailers : unit -> (Http_core.Header.t, Http_error.Error.t) Eta.Effect.t;
}

val make :
  ?headers:Http_core.Header.t ->
  ?trailers:(unit -> (Http_core.Header.t, Http_error.Error.t) Eta.Effect.t) ->
  status:int ->
  body:Http_body.Stream.t ->
  unit ->
  t
