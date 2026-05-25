(** HTTP/1.1 client loop. *)

type request_body =
  | Empty
  | Fixed of bytes list
  | Stream of Http_body.Stream.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Http_body.Stream.t;
    }

type request = {
  method_ : string;
  url : Http_core.Url.t;
  headers : Http_core.Header.t;
  body : request_body;
}

type response = {
  status : int;
  headers : Http_core.Header.t;
  body : Http_body.Stream.t;
  trailers : unit -> (Http_core.Header.t, Http_error.Error.t) Eta.Effect.t;
}

type pool

val default_max_response_body_bytes : int
(** Default maximum decoded response-body bytes for fixed-length, chunked, and
    close-delimited HTTP/1.1 responses. *)

val request_on_flow :
  ?max_response_body_bytes:int ->
  ?release:(unit -> (unit, Http_error.Error.t) Eta.Effect.t) ->
  flow:[> Eio.Flow.two_way_ty | Eio.Resource.close_ty] Eio.Resource.t ->
  request ->
  (response, Http_error.Error.t) Eta.Effect.t
(** Write one HTTP/1.1 request to [flow] and read the response.

    [max_response_body_bytes] caps fixed-length, chunked, and
    close-delimited response bodies. *)

val origin_key : Http_core.Url.t -> string
(** Stable pool key for the URL's scheme, host, and effective port. *)

val make_pool :
  ?max_response_body_bytes:int ->
  ?max_size:int ->
  ?max_idle:int ->
  ?health_check:
    (([ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
     (unit, Http_error.Error.t) Eta.Effect.t)) ->
  ?ca_file:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  Http_core.Url.t ->
  (pool, Http_error.Error.t) Eta.Effect.t
(** Build an origin-scoped h1 connection pool. [ca_file] is an optional PEM
    CA bundle added to the trust store on top of the system roots. *)

val request_with_pool :
  pool -> request -> (response, Http_error.Error.t) Eta.Effect.t
(** Execute [request] through [pool].

    [request.url] must match the pool origin. The h1 connection stays checked
    out until [response.body] reaches EOF or is discarded. *)

val pool_stats : pool -> Eta.Pool.stats
val pool_origin : pool -> string
val shutdown_pool : pool -> (unit, Http_error.Error.t) Eta.Effect.t

val request :
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  request ->
  (response, Http_error.Error.t) Eta.Effect.t
(** Connect, wrap TLS for HTTPS URLs, and execute one HTTP/1.1 request.
    [ca_file] is an optional PEM CA bundle added to the trust store. *)
