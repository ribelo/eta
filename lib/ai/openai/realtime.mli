(** Transport-neutral OpenAI Realtime protocols. *)
(** Each sibling preserves undocumented event types and their complete parsed
    JSON in [Unknown], while malformed text or binary frames fail through that
    sibling's distinct [codec_error]. *)

module Conversation : sig
  type modality = Text | Audio
  type audio_format = Pcm16_24khz | G711_ulaw | G711_alaw
  type noise_reduction = Noise_reduction_off | Near_field | Far_field
  type transcription_delay = Minimal | Low | Medium | High | Xhigh

  type input_transcription = {
    model : string option;
    language : string option;
    languages : string list;
    prompt : string option;
    keywords : string list;
    delay : transcription_delay option;
  }

  type input_transcription_setting =
    | Transcription_off
    | Transcription of input_transcription

  type turn_detection_setting =
    | Turn_detection of Eta_ai.Json.t
    | Turn_detection_off

  type voice = Named of string | Custom of string

  type tool_choice =
    | Auto_tools
    | No_tools
    | Required_tools
    | Function_tool of string
    | Mcp_tool of string
    | Other_tool_choice of Eta_ai.Json.t

  type max_output_tokens = Tokens of int | Infinite
  type tracing = Tracing_auto | Tracing_off | Tracing_config of Eta_ai.Json.t

  type truncation =
    | Truncation_auto
    | Truncation_disabled
    | Retention_ratio of { ratio : float; token_limits : Eta_ai.Json.t option }

  type session = private {
    model : string option;
    instructions : string option;
    output_modalities : modality list;
    input_audio_format : audio_format option;
    input_noise_reduction : noise_reduction option;
    input_transcription : input_transcription_setting option;
    turn_detection : turn_detection_setting option;
    output_audio_format : audio_format option;
    output_speed : float option;
    voice : voice option;
    include_logprobs : bool;
    max_output_tokens : max_output_tokens option;
    parallel_tool_calls : bool option;
    prompt : Eta_ai.Json.t option;
    reasoning : Eta_ai.Json.t option;
    tools : Eta_ai.Json.t option;
    tool_choice : tool_choice option;
    tracing : tracing option;
    truncation : truncation option;
    extra : (string * Eta_ai.Json.t) list;
  }

  val session :
    ?model:string ->
    ?instructions:string ->
    ?output_modalities:modality list ->
    ?input_audio_format:audio_format ->
    ?input_noise_reduction:noise_reduction ->
    ?input_transcription:input_transcription_setting ->
    ?turn_detection:turn_detection_setting ->
    ?output_audio_format:audio_format ->
    ?output_speed:float ->
    ?voice:voice ->
    ?include_logprobs:bool ->
    ?max_output_tokens:max_output_tokens ->
    ?parallel_tool_calls:bool ->
    ?prompt:Eta_ai.Json.t ->
    ?reasoning:Eta_ai.Json.t ->
    ?tools:Eta_ai.Json.t ->
    ?tool_choice:tool_choice ->
    ?tracing:tracing ->
    ?truncation:truncation ->
    ?extra:(string * Eta_ai.Json.t) list ->
    unit ->
    (session, Openai_error.t) Stdlib.result
  (** Validate and construct a full-fidelity Conversation session. Rejects
      empty, repeated, or mixed text-and-audio output modalities, extra fields
      colliding with owned fields, out-of-range or non-finite speed, token
      limits outside 1-4096, out-of-range or non-finite retention ratios,
      nonnumeric turn-detection fields or values outside documented ranges in
      any JSON numeric representation, documented transcription model
      restrictions, combined singular and plural transcription-language hints,
      and malformed transcription keywords before any transport. The record is
      private, so every value passes this validation. *)
  val session_json : session -> Eta_ai.Json.t
  val session_to_string : session -> Eta_ai.raw_json

  type client_secret = { value : string; expires_at : int option; raw : Eta_ai.raw_json option }
  val client_secret_request : ?base_url:string -> api_key:Eta_ai.api_key -> session -> Eta_http.Request.t
  val create_client_secret : ?base_url:string -> Eta_http.Client.t -> api_key:Eta_ai.api_key -> session -> (client_secret, Openai_error.t) Eta.Effect.t

  type client_event =
    | Session_update of { session : session; event_id : string option }
    | Input_audio_buffer_append of {
        audio : Eta_ai.audio;
        event_id : string option;
      }
    | Input_audio_buffer_commit of { event_id : string option }
    | Input_audio_buffer_clear of { event_id : string option }
    | Conversation_item_create of {
        item : Eta_ai.Json.t;
        previous_item_id : string option;
        event_id : string option;
      }
    | Conversation_item_retrieve of {
        item_id : string;
        event_id : string option;
      }
    | Conversation_item_truncate of {
        item_id : string;
        content_index : int;
        audio_end_ms : int;
        event_id : string option;
      }
    | Conversation_item_delete of {
        item_id : string;
        event_id : string option;
      }
    | Response_create of {
        response : Eta_ai.Json.t option;
        event_id : string option;
      }
    | Response_cancel of {
        response_id : string option;
        event_id : string option;
      }
    | Output_audio_buffer_clear of { event_id : string option }

  type server_error = {
    code : string option; type_ : string; message : string;
    event_id : string; param : Eta_ai.Json.t option;
    raw : Eta_ai.Json.t; full : Eta_ai.Json.t;
  }
  type server_event =
    | Session_created of Eta_ai.Json.t
    | Session_updated of Eta_ai.Json.t
    | Conversation_created of Eta_ai.Json.t
    | Conversation_item_created of Eta_ai.Json.t
    | Conversation_item_deleted of Eta_ai.Json.t
    | Conversation_item_retrieved of Eta_ai.Json.t
    | Conversation_item_truncated of Eta_ai.Json.t
    | Conversation_item_added of Eta_ai.Json.t
    | Conversation_item_done of Eta_ai.Json.t
    | Response_audio_delta of { delta : string; raw : Eta_ai.Json.t }
    | Response_audio_done of Eta_ai.Json.t
    | Response_audio_transcript_delta of {
        delta : string;
        raw : Eta_ai.Json.t;
      }
    | Response_audio_transcript_done of Eta_ai.Json.t
    | Response_text_delta of { delta : string; raw : Eta_ai.Json.t }
    | Response_created of Eta_ai.Json.t
    | Response_done of Eta_ai.Json.t
    | Input_audio_buffer_committed of Eta_ai.Json.t
    | Input_audio_buffer_cleared of Eta_ai.Json.t
    | Input_audio_speech_started of Eta_ai.Json.t
    | Input_audio_speech_stopped of Eta_ai.Json.t
    | Input_audio_timeout_triggered of Eta_ai.Json.t
    | Input_audio_dtmf_received of Eta_ai.Json.t
    | Input_audio_transcription_delta of {
        item_id : string;
        content_index : int option;
        delta : string option;
        raw : Eta_ai.Json.t;
      }
    | Input_audio_transcription_completed of {
        item_id : string;
        content_index : int;
        transcript : string;
        raw : Eta_ai.Json.t;
      }
    | Input_audio_transcription_failed of {
        item_id : string;
        content_index : int;
        error : Eta_ai.Json.t;
        raw : Eta_ai.Json.t;
      }
    | Input_audio_transcription_segment of Eta_ai.Json.t
    | Output_audio_buffer_started of Eta_ai.Json.t
    | Output_audio_buffer_stopped of Eta_ai.Json.t
    | Output_audio_buffer_cleared of Eta_ai.Json.t
    | Rate_limits_updated of Eta_ai.Json.t
    | Response_content_part_added of Eta_ai.Json.t
    | Response_content_part_done of Eta_ai.Json.t
    | Response_function_call_arguments_delta of Eta_ai.Json.t
    | Response_function_call_arguments_done of Eta_ai.Json.t
    | Response_output_item_added of Eta_ai.Json.t
    | Response_output_item_done of Eta_ai.Json.t
    | Response_output_text_done of Eta_ai.Json.t
    | Error of server_error
    | Unknown of { type_ : string; raw : Eta_ai.Json.t }
  type codec_error = Decode of { message : string; raw_body : Eta_ai.raw_json option }
  val client_event_json : client_event -> Eta_ai.Json.t
  val client_event_to_string : client_event -> Eta_ai.raw_json
  val decode_server_event : Eta_ai.raw_json -> (server_event, codec_error) result
  module Codec : sig
    include Eta_ai.Realtime.Codec with type session = session and type client_event = client_event and type server_event = server_event and type error = codec_error
  end
end

module Transcription : sig
  type audio_format = Pcm16_24khz | G711_ulaw | G711_alaw
  type noise_reduction = Disabled | Near_field | Far_field
  type delay = Minimal | Low | Medium | High | Xhigh
  type transcription = {
    model : string; language : string option; prompt : string option; keywords : string list;
    languages : string list; delay : delay option;
  }
  type session = private {
    input_audio_format : audio_format; transcription : transcription;
    noise_reduction : noise_reduction option;
    turn_detection : Eta_ai.Json.t option; include_ : string list;
  }
  val session : ?language:string -> ?prompt:string -> ?keywords:string list -> ?languages:string list -> ?delay:delay -> ?noise_reduction:noise_reduction -> ?turn_detection:Eta_ai.Json.t -> ?include_:string list -> input_audio_format:audio_format -> model:string -> unit -> (session, Openai_error.t) Stdlib.result
  (** Validate and construct a Transcription session. Rejects malformed
      keywords, documented model-specific keyword, language, prompt, delay, and
      turn-detection restrictions, combined singular and plural language hints,
      and nonnumeric turn-detection fields or values outside documented ranges
      in any JSON numeric representation before transport. Omitted or explicitly
      supplied null turn detection is encoded as JSON null. The record is
      private, so every value passes validation. *)
  val session_json : session -> Eta_ai.Json.t
  val session_to_string : session -> Eta_ai.raw_json

  type client_event =
    | Session_update of { session : session; event_id : string option }
    | Input_audio_buffer_append of { audio : Eta_ai.audio; event_id : string option }
    | Input_audio_buffer_commit of { event_id : string option }
    | Input_audio_buffer_clear of { event_id : string option }
  type language = { code : string }
  type server_error = {
    code : string option; type_ : string; message : string;
    event_id : string; param : Eta_ai.Json.t option;
    raw : Eta_ai.Json.t; full : Eta_ai.Json.t;
  }
  type server_event =
    | Session_created of Eta_ai.Json.t
    | Session_updated of Eta_ai.Json.t
    | Input_audio_buffer_committed of Eta_ai.Json.t
    | Input_audio_buffer_cleared of { event_id : string; raw : Eta_ai.Json.t }
    | Input_audio_speech_started of { event_id : string; raw : Eta_ai.Json.t }
    | Input_audio_speech_stopped of { event_id : string; raw : Eta_ai.Json.t }
    | Transcription_delta of { event_id : string; item_id : string; content_index : int; delta : string; raw : Eta_ai.Json.t }
    | Transcription_completed of { event_id : string; item_id : string; content_index : int; transcript : string; languages : language list option; raw : Eta_ai.Json.t }
    | Transcription_failed of {
        event_id : string;
        item_id : string;
        content_index : int;
        error : Eta_ai.Json.t;
        raw : Eta_ai.Json.t;
      }
    | Error of server_error
    | Unknown of { type_ : string; raw : Eta_ai.Json.t }
  type codec_error = Decode of { message : string; raw_body : Eta_ai.raw_json option }
  val client_event_json : client_event -> Eta_ai.Json.t
  val client_event_to_string : client_event -> Eta_ai.raw_json
  val decode_server_event : Eta_ai.raw_json -> (server_event, codec_error) result
  module Codec : sig
    include Eta_ai.Realtime.Codec with type session = session and type client_event = client_event and type server_event = server_event and type error = codec_error
  end
end

module Translation : sig
  type noise_reduction = Disabled | Near_field | Far_field
  type input_transcription = Disabled | Model of string
  type session = {
    model : string; output_language : string;
    input_transcription : input_transcription option;
    noise_reduction : noise_reduction option;
  }
  val session : ?input_transcription:input_transcription -> ?noise_reduction:noise_reduction -> model:string -> output_language:string -> unit -> session
  val session_json : session -> Eta_ai.Json.t
  val session_to_string : session -> Eta_ai.raw_json

  type client_event =
    | Session_update of { session : session; event_id : string option }
    | Input_audio_buffer_append of { audio : Eta_ai.audio; event_id : string option }
    | Session_close of { event_id : string option }
  type server_error = {
    code : string option; type_ : string; message : string;
    event_id : string; param : Eta_ai.Json.t option;
    raw : Eta_ai.Json.t; full : Eta_ai.Json.t;
  }
  type server_event =
    | Session_created of { event_id : string; session : Eta_ai.Json.t; raw : Eta_ai.Json.t }
    | Session_updated of { event_id : string; session : Eta_ai.Json.t; raw : Eta_ai.Json.t }
    | Session_closed of { event_id : string; raw : Eta_ai.Json.t }
    | Input_transcript_delta of { event_id : string; delta : string; elapsed_ms : int option; raw : Eta_ai.Json.t }
    | Output_transcript_delta of { event_id : string; delta : string; elapsed_ms : int option; raw : Eta_ai.Json.t }
    | Output_audio_delta of { event_id : string; delta : string; channels : int option; elapsed_ms : int option; format : [ `Pcm16 ] option; sample_rate : int option; raw : Eta_ai.Json.t }
    | Error of server_error
    | Unknown of { type_ : string; raw : Eta_ai.Json.t }
  type codec_error = Decode of { message : string; raw_body : Eta_ai.raw_json option }
  val client_event_json : client_event -> Eta_ai.Json.t
  val client_event_to_string : client_event -> Eta_ai.raw_json
  val decode_server_event : Eta_ai.raw_json -> (server_event, codec_error) result
  module Codec : sig
    include Eta_ai.Realtime.Codec with type session = session and type client_event = client_event and type server_event = server_event and type error = codec_error
  end
end
