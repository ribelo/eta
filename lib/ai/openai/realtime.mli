(** OpenAI Realtime session and WebSocket API. *)

type modality = Text | Audio

type session = {
  model : string option;
  instructions : string option;
  output_modalities : modality list;
  input_audio_format : Eta_ai.audio_format option;
  output_audio_format : Eta_ai.audio_format option;
  voice : string option;
  turn_detection : Eta_ai.Json.t option;
  tools : Eta_ai.Json.t option;
  tool_choice : string option;
  max_output_tokens : int option;
}

val session :
  ?model:string ->
  ?instructions:string ->
  ?output_modalities:modality list ->
  ?input_audio_format:Eta_ai.audio_format ->
  ?output_audio_format:Eta_ai.audio_format ->
  ?voice:string ->
  ?turn_detection:Eta_ai.Json.t ->
  ?tools:Eta_ai.Json.t ->
  ?tool_choice:string ->
  ?max_output_tokens:int ->
  unit ->
  session

val session_json : session -> Eta_ai.Json.t
val session_to_string : session -> Eta_ai.raw_json

type client_secret = {
  value : string;
  expires_at : int option;
  raw : Eta_ai.raw_json option;
}

val client_secret_request :
  ?base_url:string -> api_key:Eta_ai.api_key -> session -> Eta_http.Request.t

val create_client_secret :
  ?base_url:string ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  session ->
  (client_secret, Eta_ai.ai_error) Eta.Effect.t

type client_event =
  | Session_update of session
  | Input_audio_buffer_append of Eta_ai.audio
  | Input_audio_buffer_commit
  | Response_create
  | Raw_client_event of Eta_ai.Json.t

type server_error = {
  code : string option;
  message : string;
  raw : Eta_ai.raw_json option;
}

type server_event =
  | Session_created of Eta_ai.raw_json option
  | Response_audio_delta of string
  | Response_text_delta of string
  | Response_done of Eta_ai.raw_json option
  | Input_audio_buffer_committed
  | Server_error of server_error
  | Server_decode_error of { message : string; raw : Eta_ai.raw_json option }
  | Raw_server_event of { type_ : string option; raw : Eta_ai.raw_json }

type realtime_error = Eta_http_eio.Ws.Client.ws_error

val client_event_json : client_event -> Eta_ai.Json.t
val client_event_to_string : client_event -> Eta_ai.raw_json
val decode_server_event : Eta_ai.raw_json -> server_event

type t

val connect :
  ?base_url:string ->
  ?safety_identifier:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Eta_ai.api_key ->
  model:string ->
  unit ->
  (t, Eta_http_eio.Ws.Client.ws_error) Eta.Effect.t

val send_event : t -> client_event -> (unit, realtime_error) Eta.Effect.t
val events : t -> (server_event, Eta_http_eio.Ws.Client.ws_error) Eta_stream.Stream.t
val close : t -> (unit, Eta_http_eio.Ws.Client.ws_error) Eta.Effect.t
