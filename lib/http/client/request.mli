(** Public eta-http request model. *)

module Response_idle_timeout : sig
  type t

  val disabled : t
  val default : t
  val of_ms : int -> t
  val to_ms : t -> int option
end
(** Native response-progress timeout configuration.

    [disabled] disables response idle timeouts. [default] is 300,000 ms.
    [of_ms milliseconds] creates an enabled timeout and rejects nonpositive
    values with [Invalid_argument]. [to_ms] returns [None] for [disabled] and
    [Some milliseconds] for enabled timeouts. *)

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
  response_idle_timeout : Response_idle_timeout.t;
}
(** Eta's native HTTP/1.1 and HTTP/2 clients interpret
    [response_idle_timeout] as the maximum duration of one response-progress
    wait.

    Each response-header wait receives a fresh timeout, including the wait
    after an informational response. After final headers, each requested body
    chunk receives a fresh timeout. Header expiry fails with
    [Response_header_timeout], and body expiry fails with
    [Response_body_idle_timeout]; both are typed retryable transport failures. *)

val make :
  ?headers:Header.t ->
  ?body:body ->
  ?response_idle_timeout:Response_idle_timeout.t ->
  string ->
  string ->
  t

val body_chunks : t -> int
val body_source : body -> Source.t
val method_value : t -> Method.t
val url : t -> Url.t
