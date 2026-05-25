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
val default_max_response_body_bytes : int
(** Default maximum decoded response-body bytes for fixed-length, chunked, and
    close-delimited HTTP/1.1 responses. *)

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
  ?max_response_body_bytes:int ->
  unit ->
  t
(** Build the S1 HTTP/1.1 client path.

    Connections are pooled per origin with {!Eta.Pool}.
    [max_response_body_bytes] caps fixed-length, chunked, and
    close-delimited response bodies. *)

val make :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?max_response_body_bytes:int ->
  unit ->
  t
(** Build the S2 ALPN-dispatch client path.

    HTTPS requests negotiate [h2, http/1.1] and dispatch to the h2
    multiplexer or h1 request loop from the same caller API. Plain HTTP uses
    the h1 request loop. [max_response_body_bytes] caps HTTP/1.1 response body
    decoding. *)

val make_for_test :
  protocol:protocol ->
  request:(Request.t -> (Response.t, Eta_http_error.Error.t) Eta.Effect.t) ->
  stats:(unit -> (stats, Eta_http_error.Error.t) Eta.Effect.t) ->
  shutdown:(unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t) ->
  t

module For_test : sig
  val dispatch_alpn :
    close:(unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t) ->
    use_h1:(unit -> ('a, Eta_http_error.Error.t) Eta.Effect.t) ->
    use_h2:(unit -> ('a, Eta_http_error.Error.t) Eta.Effect.t) ->
    Request.t ->
    string option ->
    ('a, Eta_http_error.Error.t) Eta.Effect.t

  val h2_informational_status : int -> bool

  val request_h2_on_connection :
    Eta_http_h2.Connection.t ->
    Request.t ->
    Eta_http_core.Url.t ->
    (Response.t, Eta_http_error.Error.t) Eta.Effect.t
end
