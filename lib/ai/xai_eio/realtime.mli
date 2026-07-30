(** Eio transport for xAI conversational Realtime. *)

type error =
  [ Eta_http_eio.Ws.Client.ws_error
  | `Decode of string
  | `Invalid_request of string
  | `Xai_error of Eta_ai_xai.Error.t
  ]
type t

val connect_api_key :
  ?ca_file:string ->
  ?call_id:string ->
  ?conversation_id:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Eta_ai.api_key ->
  session:Eta_ai_xai.Audio.Realtime.session ->
  unit ->
  (t, error) Eta.Effect.t

val connect_ephemeral :
  ?ca_file:string ->
  ?conversation_id:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  secret:Eta_ai_xai.Audio.Realtime.client_secret ->
  session:Eta_ai_xai.Audio.Realtime.session ->
  unit ->
  (t, error) Eta.Effect.t

val send_event :
  t -> Eta_ai_xai.Audio.Realtime.client_event -> (unit, error) Eta.Effect.t
val send_audio : t -> bytes -> (unit, error) Eta.Effect.t
val read_event :
  t -> (Eta_ai_xai.Audio.Realtime.server_event option, error) Eta.Effect.t
val close : t -> (unit, error) Eta.Effect.t

type connection_options =
  | Connection_options : {
      conversation_id : string option;
      net : 'a Eio.Net.t;
      api_key : Eta_ai.api_key;
    } -> connection_options

module Transport : sig
  include
    Eta_ai.Realtime.Transport
      with type session = Eta_ai_xai.Audio.Realtime.session
       and type client_event = Eta_ai_xai.Audio.Realtime.client_event
       and type server_event = Eta_ai_xai.Audio.Realtime.server_event
       and type error = error
       and type scope = Eio.Switch.t
       and type connection_options = connection_options
       and type connection = t
end
