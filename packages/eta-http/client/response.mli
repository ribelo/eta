(** Public eta-http response model. *)

type t = {
  status : int;
  headers : Eta_http_core.Header.t;
  body : Eta_http_body.Stream.t;
  trailers : unit -> (Eta_http_core.Header.t, Eta_http_error.Error.t) Eta.Effect.t;
}

val make :
  ?headers:Eta_http_core.Header.t ->
  ?trailers:(unit -> (Eta_http_core.Header.t, Eta_http_error.Error.t) Eta.Effect.t) ->
  status:int ->
  body:Eta_http_body.Stream.t ->
  unit ->
  t
