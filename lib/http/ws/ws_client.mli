(** HTTP/1.1 WebSocket client transport. *)

type ws_error : immutable_data =
  [ `Connect of string
  | `Upgrade_failed of int
  | `Closed of int * string
  | `Protocol of string
  | `Timeout
  ]

type message = [ `Text of string | `Binary of bytes ]
type t

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

val default_max_frame_size : int
(** Default maximum WebSocket frame payload bytes accepted by the client before
    allocation. *)

val connect_on_flow :
  ?key:string ->
  ?max_frame_size:int ->
  ?headers:Header.t ->
  ?protocols:string list ->
  sw:Eio.Switch.t ->
  flow:flow ->
  Url.t ->
  (t, ws_error) Eta.Effect.t
(** Send the WebSocket upgrade request on an already-connected HTTP/1.1 flow. *)

val connect :
  ?ca_file:string ->
  ?key:string ->
  ?max_frame_size:int ->
  ?headers:Header.t ->
  ?protocols:string list ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  string ->
  (t, ws_error) Eta.Effect.t
(** Connect to a [ws://] or [wss://] URL and complete the WebSocket upgrade. *)

val incoming : t -> (message, ws_error) Eta_stream.Stream.t
val selected_protocol : t -> string option

val send_text : t -> string -> (unit, ws_error) Eta.Effect.t
val send_binary : t -> bytes -> (unit, ws_error) Eta.Effect.t
val close : ?code:int -> ?reason:string -> t -> (unit, ws_error) Eta.Effect.t
