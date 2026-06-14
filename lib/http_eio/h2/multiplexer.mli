(** HTTP/2 multiplexer adapter pieces. *)

type t
type stream = Stream_state.stream

type request_error =
  | Admission_rejected of { limit : int }
  | Connection_closed
  | Request_failed of string

type opened_request = {
  stream : stream;
  request_body : Eta_http.H2.Body.Writer.t;
}

type client_reader

type read_result =
  | Read of int
  | Eof of int
  | Close
  | Security_error of Error.kind

val create :
  ?max_concurrent:int ->
  ?config:Eta_http.H2.Config.t ->
  ?security:Security.t ->
  ?error_handler:(Eta_http.H2.Connection.error -> unit) ->
  unit ->
  t

val client_connection : t -> Eta_http.H2.Connection.t
val stats : t -> Stream_state.stats
val mark_complete : t -> stream -> unit
val mark_remote_reset : t -> int -> unit
val release : t -> stream -> Stream_state.release
val shutdown : t -> unit

val request :
  t ->
  tag:int ->
  ?trailers_handler:(Eta_http.H2.Headers.t -> unit) ->
  Eta_http.H2.Connection.Client.request ->
  error_handler:(stream -> Eta_http.H2.Connection.error -> unit) ->
  response_handler:
    (stream ->
    Eta_http.H2.Connection.Client.response ->
    Eta_http.H2.Body.Reader.t ->
    unit) ->
  (opened_request, request_error) result

val create_client_reader :
  now_ms:(unit -> int64) ->
  ?buffer_size:int ->
  ?security:Security.t ->
  ?security_config:Security.config ->
  Eta_http.H2.Connection.t ->
  client_reader

val create_reader :
  now_ms:(unit -> int64) ->
  ?buffer_size:int ->
  ?security_config:Security.config ->
  t ->
  client_reader
(** Create a reader bound to [t]'s connection state machine. *)

val client : client_reader -> Eta_http.H2.Connection.t

val read_client_once :
  flow:[> Eio.Flow.source_ty] Eio.Resource.t ->
  client_reader ->
  read_result
(** Feed one HTTP/2 client-read step from [flow]. Raw frame bytes are observed by
    the security scanner before they are passed into the in-house connection
    state machine. Flow read failures are returned as typed security errors
    instead of being raised. *)

val body_stream :
  ?poll_error:(unit -> Error.t option) ->
  ?on_eof:(unit -> unit) ->
  ?on_release:
    (Stream_state.release -> (unit, Error.t) Eta.Effect.t) ->
  closed_error:Error.t ->
  pump:(unit -> (read_result, Error.t) Eta.Effect.t) ->
  t ->
  stream ->
  Eta_http.H2.Body.Reader.t ->
  Stream.t

val body_stream_async :
  ?poll_error:(unit -> Error.t option) ->
  ?on_eof:(unit -> unit) ->
  ?on_release:
    (Stream_state.release -> (unit, Error.t) Eta.Effect.t) ->
  closed_error:Error.t ->
  t ->
  stream ->
  Eta_http.H2.Body.Reader.t ->
  Stream.t * (unit -> unit)
(** Like {!body_stream}, but waits for callbacks delivered by a background
    owner reader instead of reading the socket itself. The second result wakes a
    blocked reader when external state such as [poll_error] changes.

    Pull-based with backpressure: each consumer demand arms at most one upstream
    [Eta_http.H2.Body.Reader.schedule_read], so the internal buffer never runs
    more than one chunk ahead of the consumer even when the state machine
    delivers synchronously from a large pre-buffered frame. The full body is
    delivered without loss, including data still buffered after EOF. *)
