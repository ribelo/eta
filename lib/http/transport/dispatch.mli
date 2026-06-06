(** Protocol dispatch policy for negotiated HTTP transports. *)

type protocol = H1 | H2
type decision = Use_h1 | Use_h2

val protocol_to_string : protocol -> string
val decision_protocol : decision -> protocol

val decide_alpn : string option -> (decision, string) result
(** Convert a negotiated ALPN value into an eta-http protocol route.

    [None] is HTTP/1.1 for servers that complete TLS without ALPN. Unknown
    protocol strings are returned to the caller so they can be reported with
    request context. *)

val dispatch_alpn :
  close:(unit -> (unit, Error.t) Eta.Effect.t) ->
  use_h1:(unit -> ('a, Error.t) Eta.Effect.t) ->
  use_h2:(unit -> ('a, Error.t) Eta.Effect.t) ->
  Request.t ->
  string option ->
  ('a, Error.t) Eta.Effect.t
(** Run the selected protocol branch for a negotiated ALPN value. Unsupported
    ALPN values close the underlying transport before failing with an
    [Alpn_negotiation] TLS error. *)
