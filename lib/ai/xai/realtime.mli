(** Transport-neutral xAI Realtime speech protocol and client-secret REST call. *)

type audio_format
val pcm : sample_rate:int -> (audio_format, Xai_error.t) result
val pcmu : audio_format
val pcma : audio_format
val opus : audio_format
val audio_format_mime : audio_format -> string
val audio_format_sample_rate : audio_format -> int
val audio_format_channels : audio_format -> int

type audio_transport = Json | Binary

type turn_detection = {
  enabled : bool;
  threshold : float option;
  silence_duration_ms : int option;
  prefix_padding_ms : int option;
  idle_timeout_ms : int option;
}

type transcription = {
  language_hint : string option;
  keyterms : string list;
}

type input_audio = {
  format : audio_format;
  transport : audio_transport;
  transcription : transcription option;
}

type output_audio = {
  format : audio_format;
  transport : audio_transport;
  speed : float option;
}

type function_tool = {
  name : string;
  description : string option;
  parameters : Eta_ai.Json.t;
}

type web_location = {
  country : string option;
  city : string option;
  region : string option;
  timezone : string option;
}

type web_search = {
  location : web_location option;
  allowed_domains : string list;
  excluded_domains : string list;
  enable_image_understanding : bool option;
}

type x_search = {
  allowed_x_handles : string list;
  excluded_x_handles : string list;
  from_date : string option;
  to_date : string option;
  enable_image_understanding : bool option;
  enable_video_understanding : bool option;
}

type file_search = {
  vector_store_ids : string list;
  max_num_results : int option;
}

type mcp = {
  server_url : string;
  server_label : string;
  server_description : string option;
  allowed_tools : string list;
  authorization : string option;
  headers : (string * string) list;
}

type tool =
  | Function of function_tool
  | Web_search of web_search
  | X_search of x_search
  | File_search of file_search
  | Mcp of mcp

type session = private {
  instructions : string option;
  model : string option;
  reasoning_effort : string option;
  voice : string option;
  tools : tool list;
  turn_detection : turn_detection option;
  resumption_enabled : bool option;
  replace : (string * string) list;
  input_audio : input_audio option;
  output_audio : output_audio option;
}

val session :
  ?instructions:string ->
  ?model:string ->
  ?reasoning_effort:string ->
  ?voice:string ->
  ?tools:tool list ->
  ?turn_detection:turn_detection ->
  ?resumption_enabled:bool ->
  ?replace:(string * string) list ->
  ?input_audio:input_audio ->
  ?output_audio:output_audio ->
  unit ->
  (session, Xai_error.t) result

val session_json : session -> Eta_ai.Json.t
val session_to_string : session -> Eta_ai.raw_json

type conversation_item =
  | Message_item of Eta_ai.Json.t
  | Function_call_output of {
      call_id : string;
      output : string;
    }

type client_event =
  | Session_update of session
  | Input_audio_buffer_append of bytes
  | Input_audio_binary of bytes
  | Input_audio_buffer_commit
  | Input_audio_buffer_clear
  | Conversation_item_create of conversation_item
  | Conversation_item_delete of { item_id : string }
  | Conversation_item_truncate of {
      item_id : string;
      content_index : int;
      audio_end_ms : int;
    }
  | Response_create of Eta_ai.Json.t option
  | Response_cancel of { response_id : string option }

type server_error = {
  code : string option;
  type_ : string option;
  message : string option;
  raw : Eta_ai.Json.t;
}

type server_event =
  | Session_created of Eta_ai.Json.t
  | Session_updated of Eta_ai.Json.t
  | Conversation_created of Eta_ai.Json.t
  | Conversation_item_added of Eta_ai.Json.t
  | Conversation_item_deleted of Eta_ai.Json.t
  | Conversation_item_truncated of Eta_ai.Json.t
  | Input_audio_speech_started of Eta_ai.Json.t
  | Input_audio_speech_stopped of Eta_ai.Json.t
  | Input_audio_committed of Eta_ai.Json.t
  | Input_audio_cleared of Eta_ai.Json.t
  | Input_audio_timeout_triggered of Eta_ai.Json.t
  | Input_audio_transcription_completed of {
      transcript : string option;
      raw : Eta_ai.Json.t;
    }
  | Input_audio_transcription_updated of {
      transcript : string option;
      raw : Eta_ai.Json.t;
    }
  | Response_created of Eta_ai.Json.t
  | Response_output_audio_delta of {
      audio : bytes;
      raw : Eta_ai.Json.t;
    }
  | Response_output_audio_done of Eta_ai.Json.t
  | Response_output_audio_transcript_delta of {
      delta : string option;
      raw : Eta_ai.Json.t;
    }
  | Response_output_audio_transcript_done of Eta_ai.Json.t
  | Response_text_delta of {
      delta : string option;
      raw : Eta_ai.Json.t;
    }
  | Response_output_text_delta of {
      delta : string option;
      raw : Eta_ai.Json.t;
    }
  | Response_done of Eta_ai.Json.t
  | Dtmf_event_received of Eta_ai.Json.t
  | Error of server_error
  | Binary_audio of bytes
  | Unknown of {
      type_ : string option;
      raw : Eta_ai.Json.t;
    }

type codec_error =
  | Invalid_json of string
  | Invalid_base64_audio

val client_event_json : client_event -> Eta_ai.Json.t option
val client_event_message : client_event -> Eta_ai.Realtime.message
val decode_server_event :
  Eta_ai.Realtime.message -> (server_event, codec_error) result

module Codec : sig
  include
    Eta_ai.Realtime.Codec
      with type session = session
       and type client_event = client_event
       and type server_event = server_event
       and type error = codec_error
end

type client_secret = private string Eta_redacted.t
val client_secret : string -> client_secret
val client_secret_redacted : client_secret -> string Eta_redacted.t

type client_secret_response = {
  value : client_secret;
  expires_at : int64 option;
  raw : Eta_ai.raw_json;
}

val client_secret_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  expires_after_s:int ->
  unit ->
  (Eta_http.Request.t, Xai_error.t) result

val create_client_secret :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  expires_after_s:int ->
  (client_secret_response, Xai_error.t) Eta.Effect.t
