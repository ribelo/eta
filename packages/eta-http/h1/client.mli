(** HTTP/1.1 client loop. *)

type request_body =
  | Empty
  | Fixed of bytes list
  | Stream of Eta_http_body.Stream.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Eta_http_body.Stream.t;
    }

type request = {
  method_ : string;
  url : Eta_http_core.Url.t;
  headers : Eta_http_core.Header.t;
  body : request_body;
}

type response = {
  status : int;
  headers : Eta_http_core.Header.t;
  body : Eta_http_body.Stream.t;
  trailers : unit -> (Eta_http_core.Header.t, Eta_http_error.Error.t) Eta.Effect.t;
}

type pool

val request_on_flow :
  ?release:(unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t) ->
  flow:[> Eio.Flow.two_way_ty | Eio.Resource.close_ty] Eio.Resource.t ->
  request ->
  (response, Eta_http_error.Error.t) Eta.Effect.t
(** Write one HTTP/1.1 request to [flow] and read a fixed-length response.

    This is the S1 request loop. Chunked transfer decoding lands in S3. *)

val origin_key : Eta_http_core.Url.t -> string
(** Stable pool key for the URL's scheme, host, and effective port. *)

val make_pool :
  ?max_size:int ->
  ?max_idle:int ->
  ?health_check:
    (([ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
     (unit, Eta_http_error.Error.t) Eta.Effect.t)) ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  authenticator:X509.Authenticator.t ->
  Eta_http_core.Url.t ->
  (pool, Eta_http_error.Error.t) Eta.Effect.t
(** Build an origin-scoped h1 connection pool. *)

val request_with_pool :
  pool -> request -> (response, Eta_http_error.Error.t) Eta.Effect.t
(** Execute [request] through [pool].

    [request.url] must match the pool origin. The h1 connection stays checked
    out until [response.body] reaches EOF or is discarded. *)

val pool_stats : pool -> Eta.Pool.stats
val pool_origin : pool -> string
val shutdown_pool : pool -> (unit, Eta_http_error.Error.t) Eta.Effect.t

val request :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  authenticator:X509.Authenticator.t ->
  request ->
  (response, Eta_http_error.Error.t) Eta.Effect.t
(** Connect, wrap TLS for HTTPS URLs, and execute one HTTP/1.1 request. *)
