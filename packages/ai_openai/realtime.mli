(** OpenAI Realtime session and WebSocket API. *)

type modality = Text | Audio

type session = {
  model : string option;
  instructions : string option;
  output_modalities : modality list;
  input_audio_format : Ai.audio_format option;
  output_audio_format : Ai.audio_format option;
  voice : string option;
  turn_detection : Ai.Json.t option;
  tools : Ai.Json.t option;
  tool_choice : string option;
  max_output_tokens : int option;
}

val session :
  ?model:string ->
  ?instructions:string ->
  ?output_modalities:modality list ->
  ?input_audio_format:Ai.audio_format ->
  ?output_audio_format:Ai.audio_format ->
  ?voice:string ->
  ?turn_detection:Ai.Json.t ->
  ?tools:Ai.Json.t ->
  ?tool_choice:string ->
  ?max_output_tokens:int ->
  unit ->
  session

val session_json : session -> Ai.Json.t
val session_to_string : session -> Ai.raw_json

type client_secret = {
  value : string;
  expires_at : int option;
  raw : Ai.raw_json option;
}

val client_secret_request :
  ?base_url:string -> api_key:Ai.api_key -> session -> Http.Request.t

val create_client_secret :
  ?base_url:string ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  session ->
  (client_secret, Ai.ai_error) Eta.Effect.t

type client_event =
  | Session_update of session
  | Input_audio_buffer_append of Ai.audio
  | Input_audio_buffer_commit
  | Response_create
  | Raw_client_event of Ai.Json.t

type server_error = {
  code : string option;
  message : string;
  raw : Ai.raw_json option;
}

type server_event =
  | Session_created of Ai.raw_json option
  | Response_audio_delta of string
  | Response_text_delta of string
  | Response_done of Ai.raw_json option
  | Input_audio_buffer_committed
  | Server_error of server_error
  | Server_decode_error of { message : string; raw : Ai.raw_json option }
  | Raw_server_event of { type_ : string option; raw : Ai.raw_json }

type realtime_error = [ Http.Ws.Client.ws_error | `Encode of string ]

val client_event_json : client_event -> (Ai.Json.t, realtime_error) result
val client_event_to_string : client_event -> (Ai.raw_json, realtime_error) result
val decode_server_event : Ai.raw_json -> server_event

type t

val connect :
  ?base_url:string ->
  ?safety_identifier:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Ai.api_key ->
  model:string ->
  unit ->
  (t, Http.Ws.Client.ws_error) Eta.Effect.t

val send_event : t -> client_event -> (unit, realtime_error) Eta.Effect.t
val events : t -> (server_event, Http.Ws.Client.ws_error) Stream.Stream.t
val close : t -> (unit, Http.Ws.Client.ws_error) Eta.Effect.t
