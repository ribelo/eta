(** Eio WebSocket transport for OpenAI Realtime. *)

type realtime_error =
  [ Eta_http_eio.Ws.Client.ws_error
  | `Openai_error of Eta_ai_openai.Error.t
  ]
(** Transport errors plus structured nominal OpenAI failures. *)
type t

type connection_options =
  | Connection_options : {
      base_url : string option;
      safety_identifier : string option;
      net : 'a Eio.Net.t;
      api_key : Eta_ai.api_key;
    } -> connection_options

val connect :
  ?base_url:string ->
  ?safety_identifier:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Eta_ai.api_key ->
  model:string ->
  unit ->
  (t, realtime_error) Eta.Effect.t

val connect_session_on_flow :
  ?key:string ->
  ?safety_identifier:string ->
  sw:Eio.Switch.t ->
  flow:Eta_http_eio.Ws.Client.flow ->
  api_key:Eta_ai.api_key ->
  Eta_http.Core.Url.t ->
  Eta_ai_openai.Realtime.session ->
  (t, realtime_error) Eta.Effect.t

val send_event :
  t ->
  Eta_ai_openai.Realtime.client_event ->
  (unit, realtime_error) Eta.Effect.t

val events :
  t ->
  (Eta_ai_openai.Realtime.server_event, realtime_error) Eta_stream.Stream.t

val read_event :
  t ->
  (Eta_ai_openai.Realtime.server_event option, realtime_error) Eta.Effect.t

val close : t -> (unit, realtime_error) Eta.Effect.t

module Transport : sig
  include
    Eta_ai.Realtime.Transport
      with type session = Eta_ai_openai.Realtime.session
       and type client_event = Eta_ai_openai.Realtime.client_event
       and type server_event = Eta_ai_openai.Realtime.server_event
       and type error = realtime_error
       and type scope = Eio.Switch.t
       and type connection_options = connection_options
       and type connection = t
end
