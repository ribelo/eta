(** Top-level eta-http client API. *)

type protocol = H1 | H2 | Auto

type stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}

type t

val protocol_to_string : protocol -> string
val protocol : t -> protocol
val stats : t -> (stats, Eta_http_error.Error.t) Eta.Effect.t
val shutdown : t -> (unit, Eta_http_error.Error.t) Eta.Effect.t
val request : t -> Request.t -> (Response.t, Eta_http_error.Error.t) Eta.Effect.t
val request_with_retry :
  ?policy:Retry.t ->
  t ->
  Request.t ->
  (Response.t, Eta_http_error.Error.t) Eta.Effect.t

val make_h1 :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  authenticator:X509.Authenticator.t ->
  unit ->
  t
(** Build the S1 HTTP/1.1 client path.

    Connections are pooled per origin with {!Eta.Pool}. *)

val make :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  authenticator:X509.Authenticator.t ->
  unit ->
  t
(** Build the S2 ALPN-dispatch client path.

    HTTPS requests negotiate [h2, http/1.1] and dispatch to the h2
    multiplexer or h1 request loop from the same caller API. Plain HTTP uses
    the h1 request loop. *)

val make_for_test :
  protocol:protocol ->
  request:(Request.t -> (Response.t, Eta_http_error.Error.t) Eta.Effect.t) ->
  stats:(unit -> (stats, Eta_http_error.Error.t) Eta.Effect.t) ->
  shutdown:(unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t) ->
  t
