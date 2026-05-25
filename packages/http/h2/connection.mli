(** Owned HTTP/2 client connection loop.

    A connection owns the Eio flow and runs one reader fiber plus one writer
    fiber. Request callers open streams through the multiplexer; they never read
    from or write to the socket directly. *)

type t

type flow = Http_transport.Connect.tcp_flow

val create :
  sw:Eio.Switch.t ->
  flow:flow ->
  ?max_concurrent:int ->
  ?config:H2.Config.t ->
  ?push_handler:
    (H2.Request.t -> (H2.Client_connection.response_handler, unit) result) ->
  ?error_handler:(H2.Client_connection.error -> unit) ->
  ?security_error_handler:(Http_error.Error.kind -> unit) ->
  ?on_close:(unit -> unit) ->
  ?reader_buffer_size:int ->
  unit ->
  t

val request :
  t ->
  tag:int ->
  ?trailers_handler:(H2.Headers.t -> unit) ->
  H2.Request.t ->
  error_handler:(Multiplexer.stream -> H2.Client_connection.error -> unit) ->
  response_handler:(Multiplexer.stream -> H2.Response.t -> H2.Body.Reader.t -> unit) ->
  (Multiplexer.opened_request, Multiplexer.request_error) result

val register_failure_handler :
  t -> (Http_error.Error.kind -> unit) -> (unit -> unit)

val mux : t -> Multiplexer.t
val client : t -> H2.Client_connection.t
val stats : t -> Stream_state.stats
val fork_daemon : t -> (unit -> unit) -> unit
val is_closed : t -> bool
val shutdown : t -> unit
