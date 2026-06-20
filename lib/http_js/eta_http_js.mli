(** js_of_ocaml Fetch client adapter for eta-http.

    The adapter is client-only and uses [globalThis.fetch]. It does not install
    a Fetch polyfill, does not expose server APIs, and does not attach itself
    to {!Eta_jsoo.Runtime} by default. *)

val default_max_buffered_request_body_bytes : int
(** Default cap for eagerly collected rewindable request bodies. *)

val runtime_service :
  ?max_buffered_request_body_bytes:int ->
  unit ->
  Eta.Runtime_contract.service
(** Build an HTTP client runtime service for {!Eta_http.Client.make_runtime}.

    [max_response_body_bytes] is taken from the shared
    {!Eta_http.Client.make_runtime} options. *)

module Client : sig
  val make :
    ?max_response_body_bytes:int ->
    ?max_buffered_request_body_bytes:int ->
    unit ->
    Eta_http.Client.t
  (** Build a direct Fetch-backed {!Eta_http.Client.t}. *)
end
