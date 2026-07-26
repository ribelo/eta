(** Public eta-http request model. *)

type body =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Stream.t);
    }

type t = {
  method_ : string;
  uri : string;
  headers : Header.t;
  body : body;
  response_idle_timeout_ms : int;
}
(** Eta's native HTTP/1.1 and HTTP/2 clients interpret
    [response_idle_timeout_ms] as the maximum duration of one response-progress
    wait. The default is 300,000 ms; zero disables the timeout, and negative
    values are rejected.

    Each response-header wait receives a fresh timeout, including the wait
    after an informational response. After final headers, each requested body
    chunk receives a fresh timeout. Header expiry fails with
    [Response_header_timeout], and body expiry fails with
    [Response_body_idle_timeout]; both are typed retryable transport failures. *)

val default_response_idle_timeout_ms : int
val make :
  ?headers:Header.t ->
  ?body:body ->
  ?response_idle_timeout_ms:int ->
  string ->
  string ->
  t

val body_chunks : t -> int
val body_source : body -> Source.t
val method_value : t -> Method.t
val url : t -> Url.t
