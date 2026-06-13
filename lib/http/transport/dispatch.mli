(** Protocol dispatch policy for negotiated HTTP transports. *)

type protocol = H1 | H2
type decision = Use_h1 | Use_h2
type enabled_protocols = private { h1 : bool; h2 : bool }
type alpn_error = Missing_alpn | Unsupported_alpn of string

val protocol_to_string : protocol -> string
val decision_protocol : decision -> protocol

val enabled_protocols : h1:bool -> h2:bool -> enabled_protocols
val mixed_protocols : enabled_protocols
val enabled_protocols_of_alpn_protocols : string list -> enabled_protocols

val alpn_error_to_string : alpn_error -> string
val alpn_error_message : alpn_error -> string

val decide_alpn :
  enabled_protocols:enabled_protocols ->
  string option ->
  (decision, alpn_error) result
(** Convert a negotiated ALPN value into an eta-http protocol route under an
    explicit server/client policy.

    [None] routes to HTTP/1.1 only when [enabled_protocols.h1] is true.
    Unknown or disabled protocol strings are returned to the caller so they can
    be reported with request context. *)

val dispatch_alpn :
  enabled_protocols:enabled_protocols ->
  close:(unit -> (unit, Error.t) Eta.Effect.t) ->
  use_h1:(unit -> ('a, Error.t) Eta.Effect.t) ->
  use_h2:(unit -> ('a, Error.t) Eta.Effect.t) ->
  Request.t ->
  string option ->
  ('a, Error.t) Eta.Effect.t
(** Run the selected protocol branch for a negotiated ALPN value. Unsupported
    ALPN values close the underlying transport before failing with an
    [Alpn_negotiation] TLS error. *)
