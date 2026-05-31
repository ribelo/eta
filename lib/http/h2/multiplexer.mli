(** HTTP/2 multiplexer adapter pieces. *)

type t
type stream = Stream_state.stream

type request_error =
  | Admission_rejected of { limit : int }
  | Connection_closed
  | Request_failed of string

type opened_request = {
  stream : stream;
  request_body : H2.Body.Writer.t;
}

type client_reader

type read_result =
  | Read of int
  | Eof of int
  | Close
  | Security_error of Error.kind

val create :
  ?max_concurrent:int ->
  ?config:H2.Config.t ->
  ?push_handler:
    (H2.Request.t -> (H2.Client_connection.response_handler, unit) result) ->
  ?security:Security.t ->
  ?error_handler:(H2.Client_connection.error -> unit) ->
  unit ->
  t

val client_connection : t -> H2.Client_connection.t
val stats : t -> Stream_state.stats
val mark_complete : t -> stream -> unit
val mark_remote_reset : t -> int -> unit
val release : t -> stream -> Stream_state.release
val shutdown : t -> unit

val request :
  t ->
  tag:int ->
  ?trailers_handler:(H2.Headers.t -> unit) ->
  H2.Request.t ->
  error_handler:(stream -> H2.Client_connection.error -> unit) ->
  response_handler:(stream -> H2.Response.t -> H2.Body.Reader.t -> unit) ->
  (opened_request, request_error) result

val create_client_reader :
  ?buffer_size:int ->
  ?security:Security.t ->
  ?security_config:Security.config ->
  H2.Client_connection.t ->
  client_reader
val client : client_reader -> H2.Client_connection.t

val read_client_once :
  flow:[> Eio.Flow.source_ty] Eio.Resource.t ->
  client_reader ->
  read_result
(** Feed one HTTP/2 client-read step from [flow]. If buffered network bytes fill
    the adapter buffer without parser progress, returns
    [Security_error (Connection_protocol_violation { kind =
    "h2_read_buffer_exhausted"; _ })] instead of raising. *)

val body_stream :
  ?poll_error:(unit -> Error.t option) ->
  ?on_eof:(unit -> unit) ->
  ?on_release:
    (Stream_state.release -> (unit, Error.t) Eta.Effect.t) ->
  closed_error:Error.t ->
  pump:(unit -> (read_result, Error.t) Eta.Effect.t) ->
  t ->
  stream ->
  H2.Body.Reader.t ->
  Stream.t

val body_stream_async :
  ?poll_error:(unit -> Error.t option) ->
  ?on_eof:(unit -> unit) ->
  ?on_release:
    (Stream_state.release -> (unit, Error.t) Eta.Effect.t) ->
  closed_error:Error.t ->
  t ->
  stream ->
  H2.Body.Reader.t ->
  Stream.t * (unit -> unit)
(** Like {!body_stream}, but waits for callbacks delivered by a background
    owner reader instead of reading the socket itself. The second result wakes a
    blocked reader when external state such as [poll_error] changes. *)
