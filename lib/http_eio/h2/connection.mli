(** Owned HTTP/2 client connection loop.

    A connection owns the Eio flow and runs one reader fiber plus one writer
    fiber. Request callers open streams through the multiplexer; they never read
    from or write to the socket directly. *)

type t

type flow = Connect.tcp_flow

val create :
  sw:Eio.Switch.t ->
  flow:flow ->
  now_ms:(unit -> int64) ->
  ?max_concurrent:int ->
  ?config:Eta_http_h2.Config.t ->
  ?error_handler:(Eta_http_h2.Connection.error -> unit) ->
  ?security_error_handler:(Error.kind -> unit) ->
  ?on_close:(unit -> unit) ->
  ?reader_buffer_size:int ->
  unit ->
  t

val request :
  t ->
  tag:int ->
  ?trailers_handler:(Eta_http_h2.Headers.t -> unit) ->
  Eta_http_h2.Connection.Client.request ->
  error_handler:(Multiplexer.stream -> Eta_http_h2.Connection.error -> unit) ->
  response_handler:
    (Multiplexer.stream ->
    Eta_http_h2.Connection.Client.response ->
    Eta_http_h2.Body.Reader.t ->
    unit) ->
  (Multiplexer.opened_request, Multiplexer.request_error) result

val register_failure_handler :
  t -> (Error.kind -> unit) -> (unit -> unit)

val mux : t -> Multiplexer.t
val client : t -> Eta_http_h2.Connection.t
val stats : t -> Stream_state.stats
val fork_daemon : t -> (unit -> unit) -> unit
val is_closed : t -> bool
val shutdown : t -> unit
