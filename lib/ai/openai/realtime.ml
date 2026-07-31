module A = Eta_ai
module E = Eta.Effect
module Openai_error = Openai_error
module Json = A.Json

let audio_base64 = function
  | A.Base64 value -> value
  | A.Bytes bytes -> Base64.encode_string (Bytes.to_string bytes)

let strings values = Json.array (List.map Json.string values)

let decode_json raw make_error f =
  match Json.parse raw with
  | Error message -> Error (make_error message (Some raw))
  | Ok json -> f json

let required_string raw make_error name json =
  match Json.string_member name json with
  | Some value -> Ok value
  | None -> Error (make_error ("Realtime event missing string field " ^ name) (Some raw))

let required_int raw make_error name json =
  match Json.int_member name json with
  | Some value -> Ok value
  | None -> Error (make_error ("Realtime event missing integer field " ^ name) (Some raw))

let error_fields raw make_error json =
  match Json.object_member "error" json with
  | None ->
      Error
        (make_error "Realtime error event missing nested error object" (Some raw))
  | Some detail -> (
      match required_string raw make_error "event_id" json with
      | Error _ as error -> error
      | Ok event_id -> (
          match required_string raw make_error "type" detail with
          | Error _ as error -> error
          | Ok type_ -> (
              match required_string raw make_error "message" detail with
              | Error _ as error -> error
              | Ok message ->
                  Ok
                    ( Json.scalar_string_member "code" detail,
                      type_,
                      message,
                      event_id,
                      Json.member "param" detail,
                      detail ))))

let event_type raw make_error json =
  match json with
  | `Assoc _ -> required_string raw make_error "type" json
  | _ ->
      Error
        (make_error "Realtime event must be a JSON object with a string type"
           (Some raw))

let json_integer_literal value =
  let length = String.length value in
  let start = if length > 0 && value.[0] = '-' then 1 else 0 in
  if start = length then false
  else
    match value.[start] with
    | '0' -> start + 1 = length
    | '1' .. '9' ->
        let rec digits index =
          index = length
          ||
          match value.[index] with
          | '0' .. '9' -> digits (index + 1)
          | _ -> false
        in
        digits (start + 1)
    | _ -> false

let negative_nonzero_integer_literal value =
  String.length value > 0 && value.[0] = '-' && value <> "-0"

let turn_detection_number_out_of_range (name, value) =
  match name, value with
  | "idle_timeout_ms", `Null -> false
  | "threshold", `Float value ->
      not (Float.is_finite value)
      || Float.compare value 0.0 < 0
      || Float.compare value 1.0 > 0
  | "threshold", `Int value -> value < 0 || value > 1
  | "threshold", `Intlit value ->
      not (json_integer_literal value)
      || (value <> "-0" && value <> "0" && value <> "1")
  | "threshold", _ -> true
  | ("idle_timeout_ms" | "prefix_padding_ms" | "silence_duration_ms"),
    `Float value ->
      not (Float.is_finite value) || Float.compare value 0.0 < 0
  | ("idle_timeout_ms" | "prefix_padding_ms" | "silence_duration_ms"),
    `Int value -> value < 0
  | ("idle_timeout_ms" | "prefix_padding_ms" | "silence_duration_ms"),
    `Intlit value ->
      not (json_integer_literal value)
      || negative_nonzero_integer_literal value
  | ("idle_timeout_ms" | "prefix_padding_ms" | "silence_duration_ms"), _ ->
      true
  | _ -> false

let turn_detection_numbers_out_of_range = function
  | `Assoc fields -> List.exists turn_detection_number_out_of_range fields
  | _ -> false

let plural_transcription_model = function
  | "gpt-transcribe" | "gpt-live-transcribe" -> true
  | _ -> false

let known_transcription_model = function
  | "whisper-1"
  | "gpt-transcribe"
  | "gpt-live-transcribe"
  | "gpt-4o-mini-transcribe"
  | "gpt-4o-mini-transcribe-2025-12-15"
  | "gpt-4o-transcribe"
  | "gpt-4o-transcribe-diarize"
  | "gpt-realtime-whisper" -> true
  | _ -> false

module Conversation = struct
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
    | Turn_detection of A.Json.t
    | Turn_detection_off

  type voice = Named of string | Custom of string

  type tool_choice =
    | Auto_tools
    | No_tools
    | Required_tools
    | Function_tool of string
    | Mcp_tool of string
    | Other_tool_choice of A.Json.t

  type max_output_tokens = Tokens of int | Infinite
  type tracing = Tracing_auto | Tracing_off | Tracing_config of A.Json.t

  type truncation =
    | Truncation_auto
    | Truncation_disabled
    | Retention_ratio of { ratio : float; token_limits : A.Json.t option }

  type session = {
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
    prompt : A.Json.t option;
    reasoning : A.Json.t option;
    tools : A.Json.t option;
    tool_choice : tool_choice option;
    tracing : tracing option;
    truncation : truncation option;
    extra : (string * A.Json.t) list;
  }

  let owned_fields =
    [ "type"; "model"; "instructions"; "output_modalities"; "audio";
      "include"; "max_output_tokens"; "parallel_tool_calls"; "prompt";
      "reasoning"; "tools"; "tool_choice"; "tracing"; "truncation" ]

  let invalid message = Error (Openai_error.Invalid_request message)

  let session ?model ?instructions ?(output_modalities = [ Audio ])
      ?input_audio_format ?input_noise_reduction ?input_transcription
      ?turn_detection ?output_audio_format ?output_speed ?voice
      ?(include_logprobs = false) ?max_output_tokens ?parallel_tool_calls
      ?prompt ?reasoning ?tools ?tool_choice ?tracing ?truncation
      ?(extra = []) () =
    let collision =
      List.find_opt
        (fun (name, _) -> List.mem name owned_fields)
        extra
    in
    let distinct = List.sort_uniq compare output_modalities in
    match collision with
    | Some (name, _) ->
        invalid ("Realtime Conversation extra field collides with " ^ name)
    | None ->
      if output_modalities = [] then
        invalid "Realtime Conversation requires at least one output modality"
      else if List.length distinct <> List.length output_modalities then
        invalid "Realtime Conversation output modalities must not repeat"
      else if List.mem Text output_modalities && List.mem Audio output_modalities
      then
        invalid
          "Realtime Conversation cannot request text and audio output together"
      else (
        match output_speed with
        | Some value
          when not (Float.is_finite value)
               || Float.compare value 0.25 < 0
               || Float.compare value 1.5 > 0 ->
            invalid
              "Realtime Conversation output speed must be finite and between 0.25 and 1.5"
        | _ -> (
            match max_output_tokens with
            | Some (Tokens value) when value < 1 || value > 4096 ->
                invalid
                  "Realtime Conversation max_output_tokens must be between 1 and 4096"
            | _ -> (
                match input_transcription with
                | Some (Transcription transcription)
                  when List.exists
                         (fun keyword ->
                           String.contains keyword '<'
                           || String.contains keyword '>'
                           || String.contains keyword '\r'
                           || String.contains keyword '\n')
                         transcription.keywords ->
                    invalid
                      "Realtime Conversation transcription keywords must be one line and contain no '<' or '>'"
                | _ -> (
                    match truncation with
                    | Some (Retention_ratio { ratio; _ })
                      when not (Float.is_finite ratio)
                           || Float.compare ratio 0.0 < 0
                           || Float.compare ratio 1.0 > 0 ->
                        invalid
                          "Realtime Conversation retention ratio must be finite and between 0.0 and 1.0"
                    | _ ->
                      let transcription =
                        match input_transcription with
                        | Some (Transcription transcription) ->
                            Some transcription
                        | _ -> None
                      in
                      (
                        match transcription with
                        | Some { language = Some _; languages = _ :: _; _ } ->
                            invalid
                              "Realtime Conversation transcription language and languages are mutually exclusive"
                        | Some { model = Some model; language = Some _; _ }
                          when plural_transcription_model model ->
                            invalid
                              "Realtime Conversation gpt-transcribe and gpt-live-transcribe use languages instead of language"
                        | Some { model = Some model; languages = _ :: _; _ }
                          when known_transcription_model model
                               && not (plural_transcription_model model) ->
                            invalid
                              "Realtime Conversation transcription languages are supported only by gpt-transcribe and gpt-live-transcribe"
                        | Some { model = Some model; keywords = _ :: _; _ }
                          when known_transcription_model model
                               && not (plural_transcription_model model) ->
                            invalid
                              "Realtime Conversation transcription keywords are supported only by gpt-transcribe and gpt-live-transcribe"
                        | Some
                            { model = Some "gpt-realtime-whisper";
                              prompt = Some _;
                              _ } ->
                            invalid
                              "Realtime Conversation prompt is unsupported with gpt-realtime-whisper"
                        | Some
                            { model = Some "gpt-4o-transcribe-diarize";
                              prompt = Some _;
                              _ } ->
                            invalid
                              "Realtime Conversation prompt is unsupported with gpt-4o-transcribe-diarize"
                        | Some { model = Some "gpt-realtime-whisper"; _ }
                          when turn_detection <> Some Turn_detection_off ->
                            invalid
                              "Realtime Conversation turn detection must be explicitly null with gpt-realtime-whisper"
                        | Some { model = Some model; delay = Some _; _ }
                          when known_transcription_model model
                               && model <> "gpt-realtime-whisper" ->
                            invalid
                              "Realtime Conversation transcription delay is supported only with gpt-realtime-whisper"
                        | _ -> (
                        match turn_detection with
                        | Some (Turn_detection json)
                          when turn_detection_numbers_out_of_range json ->
                            invalid
                              "Realtime Conversation turn detection numeric values must be within documented ranges"
                        | _ ->
                            Ok
                              { model; instructions; output_modalities;
                        input_audio_format; input_noise_reduction;
                        input_transcription; turn_detection;
                        output_audio_format; output_speed; voice;
                        include_logprobs; max_output_tokens;
                        parallel_tool_calls; prompt; reasoning; tools;
                        tool_choice; tracing; truncation; extra }))))))

  let modality_json = function Text -> Json.string "text" | Audio -> Json.string "audio"

  let audio_format_json = function
    | Pcm16_24khz ->
        Json.object_
          [ ("type", Some (Json.string "audio/pcm"));
            ("rate", Some (Json.int 24000)) ]
    | G711_alaw -> Json.object_ [ ("type", Some (Json.string "audio/pcma")) ]
    | G711_ulaw -> Json.object_ [ ("type", Some (Json.string "audio/pcmu")) ]

  let noise_reduction_json = function
    | Noise_reduction_off -> `Null
    | Near_field ->
        Json.object_ [ ("type", Some (Json.string "near_field")) ]
    | Far_field ->
        Json.object_ [ ("type", Some (Json.string "far_field")) ]

  let transcription_delay_json = function
    | Minimal -> "minimal" | Low -> "low" | Medium -> "medium"
    | High -> "high" | Xhigh -> "xhigh"

  let input_transcription_json (transcription : input_transcription) =
    Json.object_
      [
        ("model", Option.map Json.string transcription.model);
        ("language", Option.map Json.string transcription.language);
        ("languages",
          if transcription.languages = [] then None
          else Some (strings transcription.languages));
        ("prompt", Option.map Json.string transcription.prompt);
        ("keywords",
          if transcription.keywords = [] then None
          else Some (strings transcription.keywords));
        ("delay",
          Option.map (fun delay -> Json.string (transcription_delay_json delay))
            transcription.delay);
      ]

  let voice_json = function
    | Named value -> Json.string value
    | Custom id -> Json.object_ [ ("id", Some (Json.string id)) ]

  let tool_choice_json = function
    | Auto_tools -> Json.string "auto"
    | No_tools -> Json.string "none"
    | Required_tools -> Json.string "required"
    | Function_tool name ->
        Json.object_
          [ ("type", Some (Json.string "function"));
            ("name", Some (Json.string name)) ]
    | Mcp_tool label ->
        Json.object_
          [ ("type", Some (Json.string "mcp"));
            ("server_label", Some (Json.string label)) ]
    | Other_tool_choice json -> json

  let tracing_json = function
    | Tracing_auto -> Json.string "auto"
    | Tracing_off -> `Null
    | Tracing_config json -> json

  let truncation_json = function
    | Truncation_auto -> Json.string "auto"
    | Truncation_disabled -> Json.string "disabled"
    | Retention_ratio { ratio; token_limits } ->
        Json.object_
          [ ("type", Some (Json.string "retention_ratio"));
            ("retention_ratio", Json.float ratio);
            ("token_limits", token_limits) ]

  let session_json session =
    let base =
      [
        ("type", Some (Json.string "realtime"));
        ("model", Option.map Json.string session.model);
        ("instructions", Option.map Json.string session.instructions);
        ("output_modalities",
          Some (Json.array (List.map modality_json session.output_modalities)));
        ("audio",
          Some
            (Json.object_
               [
                 ("input",
                   Some
                     (Json.object_
                        [
                          ("format",
                            Option.map audio_format_json
                              session.input_audio_format);
                          ("noise_reduction",
                            Option.map noise_reduction_json
                              session.input_noise_reduction);
                          ("transcription",
                            Option.map
                              (function
                                | Transcription_off -> `Null
                                | Transcription transcription ->
                                    input_transcription_json transcription)
                              session.input_transcription);
                          ("turn_detection",
                            Option.map
                              (function
                                | Turn_detection json -> json
                                | Turn_detection_off -> `Null)
                              session.turn_detection);
                        ]));
                 ("output",
                   Some
                     (Json.object_
                        [
                          ("format",
                            Option.map audio_format_json
                              session.output_audio_format);
                          ("speed",
                            Option.map
                              (fun value -> Option.get (Json.float value))
                              session.output_speed);
                          ("voice", Option.map voice_json session.voice);
                        ]));
               ]));
        ("include",
          if session.include_logprobs then
            Some (strings [ "item.input_audio_transcription.logprobs" ])
          else None);
        ("max_output_tokens",
          Option.map
            (function
              | Tokens value -> Json.int value
              | Infinite -> Json.string "inf")
            session.max_output_tokens);
        ("parallel_tool_calls",
          Option.map Json.bool session.parallel_tool_calls);
        ("prompt", session.prompt);
        ("reasoning", session.reasoning);
        ("tools", session.tools);
        ("tool_choice", Option.map tool_choice_json session.tool_choice);
        ("tracing", Option.map tracing_json session.tracing);
        ("truncation", Option.map truncation_json session.truncation);
      ]
    in
    let fields = base @ List.map (fun (name, value) -> (name, Some value)) session.extra in
    Json.object_ fields

  let session_to_string session = Json.to_string (session_json session)

  type client_secret = { value : string; expires_at : int option; raw : A.raw_json option }

  let auth_headers api_key =
    Eta_http.Core.Header.unsafe_of_list
      [ ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
        ("Content-Type", "application/json"); ("Accept", "application/json") ]

  let client_secret_request ?(base_url = "https://api.openai.com") ~api_key session =
    let body = Json.object_ [ ("session", Some (session_json session)) ] |> Json.to_string in
    Eta_http.Request.make ~headers:(auth_headers api_key)
      ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ]) "POST"
      (A.trim_trailing_slash base_url ^ "/v1/realtime/client_secrets")

  let decode_client_secret raw =
    match Json.parse raw with
    | Error message -> Error (Openai_error.Decode { message; raw_body = Some raw })
    | Ok json ->
        (match Json.string_member "value" json with
         | Some value -> Ok { value; expires_at = Json.int_member "expires_at" json; raw = Some raw }
         | None -> Error (Openai_error.Decode
             { message = "Realtime client secret response missing value"; raw_body = Some raw }))

  let create_client_secret ?base_url client ~api_key session =
    let request = client_secret_request ?base_url ~api_key session in
    Eta_http.request client request
    |> Eta_observability.suppress_observability
    |> E.bind_error (fun error -> E.fail (Openai_error.Http error))
    |> E.bind (fun (response : Eta_http.Response.t) ->
           Eta_http.Body.Stream.read_all response.body
           |> E.bind_error (fun error -> E.fail (Openai_error.Http error))
           |> E.map Bytes.unsafe_to_string
           |> E.bind (fun raw ->
                  if response.status >= 200 && response.status < 300 then
                    match decode_client_secret raw with Ok value -> E.pure value | Error error -> E.fail error
                  else E.fail (Openai_error.decode ~status:response.status ~headers:response.headers raw)))

  type client_event =
    | Session_update of { session : session; event_id : string option }
    | Input_audio_buffer_append of { audio : A.audio; event_id : string option }
    | Input_audio_buffer_commit of { event_id : string option }
    | Input_audio_buffer_clear of { event_id : string option }
    | Conversation_item_create of {
        item : A.Json.t;
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
        response : A.Json.t option;
        event_id : string option;
      }
    | Response_cancel of {
        response_id : string option;
        event_id : string option;
      }
    | Output_audio_buffer_clear of { event_id : string option }

  type server_error = {
    code : string option; type_ : string; message : string;
    event_id : string; param : A.Json.t option;
    raw : A.Json.t; full : A.Json.t;
  }
  type server_event =
    | Session_created of A.Json.t
    | Session_updated of A.Json.t
    | Conversation_created of A.Json.t
    | Conversation_item_created of A.Json.t
    | Conversation_item_deleted of A.Json.t
    | Conversation_item_retrieved of A.Json.t
    | Conversation_item_truncated of A.Json.t
    | Conversation_item_added of A.Json.t
    | Conversation_item_done of A.Json.t
    | Response_audio_delta of { delta : string; raw : A.Json.t }
    | Response_audio_done of A.Json.t
    | Response_audio_transcript_delta of { delta : string; raw : A.Json.t }
    | Response_audio_transcript_done of A.Json.t
    | Response_text_delta of { delta : string; raw : A.Json.t }
    | Response_created of A.Json.t
    | Response_done of A.Json.t
    | Input_audio_buffer_committed of A.Json.t
    | Input_audio_buffer_cleared of A.Json.t
    | Input_audio_speech_started of A.Json.t
    | Input_audio_speech_stopped of A.Json.t
    | Input_audio_timeout_triggered of A.Json.t
    | Input_audio_dtmf_received of A.Json.t
    | Input_audio_transcription_delta of {
        item_id : string;
        content_index : int option;
        delta : string option;
        raw : A.Json.t;
      }
    | Input_audio_transcription_completed of {
        item_id : string;
        content_index : int;
        transcript : string;
        raw : A.Json.t;
      }
    | Input_audio_transcription_failed of {
        item_id : string;
        content_index : int;
        error : A.Json.t;
        raw : A.Json.t;
      }
    | Input_audio_transcription_segment of A.Json.t
    | Output_audio_buffer_started of A.Json.t
    | Output_audio_buffer_stopped of A.Json.t
    | Output_audio_buffer_cleared of A.Json.t
    | Rate_limits_updated of A.Json.t
    | Response_content_part_added of A.Json.t
    | Response_content_part_done of A.Json.t
    | Response_function_call_arguments_delta of A.Json.t
    | Response_function_call_arguments_done of A.Json.t
    | Response_output_item_added of A.Json.t
    | Response_output_item_done of A.Json.t
    | Response_output_text_done of A.Json.t
    | Error of server_error
    | Unknown of { type_ : string; raw : A.Json.t }
  type codec_error = Decode of { message : string; raw_body : A.raw_json option }

  let client_event_json = function
    | Session_update { session; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "session.update"));
            ("session", Some (session_json session));
            ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_append { audio; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "input_audio_buffer.append"));
            ("audio", Some (Json.string (audio_base64 audio.A.data)));
            ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_commit { event_id } ->
        Json.object_
          [ ("type", Some (Json.string "input_audio_buffer.commit"));
            ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_clear { event_id } ->
        Json.object_
          [ ("type", Some (Json.string "input_audio_buffer.clear"));
            ("event_id", Option.map Json.string event_id) ]
    | Conversation_item_create { item; previous_item_id; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "conversation.item.create"));
            ("item", Some item);
            ("previous_item_id", Option.map Json.string previous_item_id);
            ("event_id", Option.map Json.string event_id) ]
    | Conversation_item_retrieve { item_id; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "conversation.item.retrieve"));
            ("item_id", Some (Json.string item_id));
            ("event_id", Option.map Json.string event_id) ]
    | Conversation_item_truncate
        { item_id; content_index; audio_end_ms; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "conversation.item.truncate"));
            ("item_id", Some (Json.string item_id));
            ("content_index", Some (Json.int content_index));
            ("audio_end_ms", Some (Json.int audio_end_ms));
            ("event_id", Option.map Json.string event_id) ]
    | Conversation_item_delete { item_id; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "conversation.item.delete"));
            ("item_id", Some (Json.string item_id));
            ("event_id", Option.map Json.string event_id) ]
    | Response_create { response; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "response.create"));
            ("response", response);
            ("event_id", Option.map Json.string event_id) ]
    | Response_cancel { response_id; event_id } ->
        Json.object_
          [ ("type", Some (Json.string "response.cancel"));
            ("response_id", Option.map Json.string response_id);
            ("event_id", Option.map Json.string event_id) ]
    | Output_audio_buffer_clear { event_id } ->
        Json.object_
          [ ("type", Some (Json.string "output_audio_buffer.clear"));
            ("event_id", Option.map Json.string event_id) ]

  let client_event_to_string event = Json.to_string (client_event_json event)
  let make_decode message raw_body = Decode { message; raw_body }

  let transcription_failed raw make_decode json make =
    Result.bind (required_string raw make_decode "item_id" json) (fun item_id ->
    Result.bind (required_int raw make_decode "content_index" json) (fun content_index ->
    match Json.object_member "error" json with
    | Some error -> Ok (make item_id content_index error json)
    | None -> Error (make_decode "transcription failure missing error" (Some raw))))

  let decode_server_event raw =
    decode_json raw make_decode @@ fun json ->
    Result.bind (event_type raw make_decode json) @@ function
    | "session.created" -> Ok (Session_created json)
    | "session.updated" -> Ok (Session_updated json)
    | "conversation.created" -> Ok (Conversation_created json)
    | "conversation.item.created" -> Ok (Conversation_item_created json)
    | "conversation.item.deleted" -> Ok (Conversation_item_deleted json)
    | "conversation.item.retrieved" -> Ok (Conversation_item_retrieved json)
    | "conversation.item.truncated" -> Ok (Conversation_item_truncated json)
    | "conversation.item.added" -> Ok (Conversation_item_added json)
    | "conversation.item.done" -> Ok (Conversation_item_done json)
    | "response.output_audio.delta" ->
        Result.map (fun delta -> Response_audio_delta { delta; raw = json })
          (required_string raw make_decode "delta" json)
    | "response.output_audio.done" -> Ok (Response_audio_done json)
    | "response.output_audio_transcript.delta" ->
        Result.map
          (fun delta -> Response_audio_transcript_delta { delta; raw = json })
          (required_string raw make_decode "delta" json)
    | "response.output_audio_transcript.done" ->
        Ok (Response_audio_transcript_done json)
    | "response.output_text.delta" ->
        Result.map (fun delta -> Response_text_delta { delta; raw = json })
          (required_string raw make_decode "delta" json)
    | "response.output_text.done" -> Ok (Response_output_text_done json)
    | "response.created" -> Ok (Response_created json)
    | "response.done" -> Ok (Response_done json)
    | "response.content_part.added" -> Ok (Response_content_part_added json)
    | "response.content_part.done" -> Ok (Response_content_part_done json)
    | "response.function_call_arguments.delta" ->
        Ok (Response_function_call_arguments_delta json)
    | "response.function_call_arguments.done" ->
        Ok (Response_function_call_arguments_done json)
    | "response.output_item.added" -> Ok (Response_output_item_added json)
    | "response.output_item.done" -> Ok (Response_output_item_done json)
    | "input_audio_buffer.committed" -> Ok (Input_audio_buffer_committed json)
    | "input_audio_buffer.cleared" -> Ok (Input_audio_buffer_cleared json)
    | "input_audio_buffer.speech_started" -> Ok (Input_audio_speech_started json)
    | "input_audio_buffer.speech_stopped" -> Ok (Input_audio_speech_stopped json)
    | "input_audio_buffer.timeout_triggered" ->
        Ok (Input_audio_timeout_triggered json)
    | "input_audio_buffer.dtmf_event_received" ->
        Ok (Input_audio_dtmf_received json)
    | "conversation.item.input_audio_transcription.delta" ->
        Result.map
          (fun item_id -> Input_audio_transcription_delta
            { item_id; content_index = Json.int_member "content_index" json;
              delta = Json.string_member "delta" json; raw = json })
          (required_string raw make_decode "item_id" json)
    | "conversation.item.input_audio_transcription.completed" ->
        Result.bind (required_string raw make_decode "item_id" json) (fun item_id ->
        Result.bind (required_int raw make_decode "content_index" json) (fun content_index ->
        Result.map (fun transcript -> Input_audio_transcription_completed
          { item_id; content_index; transcript; raw = json })
          (required_string raw make_decode "transcript" json)))
    | "conversation.item.input_audio_transcription.failed" ->
        transcription_failed raw make_decode json
          (fun item_id content_index error raw ->
            Input_audio_transcription_failed { item_id; content_index; error; raw })
    | "conversation.item.input_audio_transcription.segment" ->
        Ok (Input_audio_transcription_segment json)
    | "output_audio_buffer.started" -> Ok (Output_audio_buffer_started json)
    | "output_audio_buffer.stopped" -> Ok (Output_audio_buffer_stopped json)
    | "output_audio_buffer.cleared" -> Ok (Output_audio_buffer_cleared json)
    | "rate_limits.updated" -> Ok (Rate_limits_updated json)
    | "error" ->
        Result.bind (required_string raw make_decode "event_id" json) (fun _ ->
        Result.map
          (fun (code, type_, message, event_id, param, detail) ->
            Error
              { code; type_; message; event_id; param; raw = detail;
                full = json })
          (error_fields raw make_decode json))
    | type_ -> Ok (Unknown { type_; raw = json })

  module Codec = struct
    type nonrec session = session
    type nonrec client_event = client_event
    type nonrec server_event = server_event
    type nonrec error = codec_error
    let encode_session session =
      A.Realtime.Text
        (client_event_to_string
           (Session_update { session; event_id = None }))
    let encode_client_event event = A.Realtime.Text (client_event_to_string event)
    let decode_server_event = function
      | A.Realtime.Text raw -> decode_server_event raw
      | A.Realtime.Binary _ -> Error (make_decode "OpenAI Realtime sent binary WebSocket message" None)
  end
end

module Transcription = struct
  type audio_format = Pcm16_24khz | G711_ulaw | G711_alaw
  type noise_reduction = Disabled | Near_field | Far_field
  type delay = Minimal | Low | Medium | High | Xhigh
  type transcription = {
    model : string;
    language : string option;
    prompt : string option;
    keywords : string list;
    languages : string list;
    delay : delay option;
  }
  type session = {
    input_audio_format : audio_format;
    transcription : transcription;
    noise_reduction : noise_reduction option;
    turn_detection : A.Json.t option;
    include_ : string list;
  }

  let invalid message = Error (Openai_error.Invalid_request message)

  let malformed_keyword keyword =
    String.contains keyword '<'
    || String.contains keyword '>'
    || String.contains keyword '\r'
    || String.contains keyword '\n'

  let session ?language ?prompt ?(keywords = []) ?(languages = []) ?delay ?noise_reduction ?turn_detection
      ?(include_ = []) ~input_audio_format ~model () =
    if List.exists malformed_keyword keywords then
      invalid
        "Realtime Transcription keywords must be one line and contain no '<' or '>'"
    else if language <> None && languages <> [] then
      invalid
        "Realtime Transcription language and languages are mutually exclusive"
    else if plural_transcription_model model && language <> None then
      invalid
        "Realtime Transcription gpt-transcribe and gpt-live-transcribe use languages instead of language"
    else if
      known_transcription_model model
      && not (plural_transcription_model model)
      && keywords <> []
    then
      invalid
        "Realtime Transcription keywords are supported only by gpt-transcribe and gpt-live-transcribe"
    else if
      known_transcription_model model
      && not (plural_transcription_model model)
      && languages <> []
    then
      invalid
        "Realtime Transcription languages are supported only by gpt-transcribe and gpt-live-transcribe"
    else if model = "gpt-realtime-whisper" && prompt <> None then
      invalid
        "Realtime Transcription prompt is unsupported with gpt-realtime-whisper"
    else if model = "gpt-4o-transcribe-diarize" && prompt <> None then
      invalid
        "Realtime Transcription prompt is unsupported with gpt-4o-transcribe-diarize"
    else if
      known_transcription_model model
      && model <> "gpt-live-transcribe"
      && model <> "gpt-realtime-whisper"
      && delay <> None
    then
      invalid
        "Realtime Transcription delay is supported only by gpt-live-transcribe and gpt-realtime-whisper"
    else if
      model = "gpt-realtime-whisper"
      && turn_detection <> None
      && turn_detection <> Some `Null
    then
      invalid
        "Realtime Transcription turn detection must be null with gpt-realtime-whisper"
    else if
      match turn_detection with
      | Some json -> turn_detection_numbers_out_of_range json
      | None -> false
    then
      invalid
        "Realtime Transcription turn detection numeric values must be within documented ranges"
    else
      Ok
        { input_audio_format;
          transcription = { model; language; prompt; keywords; languages; delay };
          noise_reduction;
          turn_detection;
          include_ }

  let audio_format_json = function
    | Pcm16_24khz ->
        Json.object_
          [ ("type", Some (Json.string "audio/pcm"));
            ("rate", Some (Json.int 24000)) ]
    | G711_ulaw -> Json.object_ [ ("type", Some (Json.string "audio/pcmu")) ]
    | G711_alaw -> Json.object_ [ ("type", Some (Json.string "audio/pcma")) ]

  let noise_reduction_json = function
    | Disabled -> `Null
    | Near_field -> Json.object_ [ ("type", Some (Json.string "near_field")) ]
    | Far_field -> Json.object_ [ ("type", Some (Json.string "far_field")) ]

  let delay_string = function Minimal -> "minimal" | Low -> "low" | Medium -> "medium" | High -> "high" | Xhigh -> "xhigh"

  let session_json session =
    let t = session.transcription in
    Json.object_
      [
        ("type", Some (Json.string "transcription"));
        ("audio", Some (Json.object_
           [ ("input", Some (Json.object_
               [
                 ("format", Some (audio_format_json session.input_audio_format));
                 ("noise_reduction",
                   Option.map noise_reduction_json session.noise_reduction);
                 ("transcription", Some (Json.object_
                    [ ("model", Some (Json.string t.model));
                      ("language", Option.map Json.string t.language);
                      ("prompt", Option.map Json.string t.prompt);
                      ("keywords", if t.keywords = [] then None else Some (strings t.keywords));
                      ("languages", if t.languages = [] then None else Some (strings t.languages));
                      ("delay", Option.map (fun value -> Json.string (delay_string value)) t.delay) ]));
                 ("turn_detection", Some (Option.value ~default:`Null session.turn_detection));
               ])) ]));
        ("include", if session.include_ = [] then None else Some (strings session.include_));
      ]
  let session_to_string session = Json.to_string (session_json session)

  type client_event =
    | Session_update of { session : session; event_id : string option }
    | Input_audio_buffer_append of { audio : A.audio; event_id : string option }
    | Input_audio_buffer_commit of { event_id : string option }
    | Input_audio_buffer_clear of { event_id : string option }
  type language = { code : string }
  type server_error = {
    code : string option; type_ : string; message : string;
    event_id : string; param : A.Json.t option;
    raw : A.Json.t; full : A.Json.t;
  }
  type server_event =
    | Session_created of A.Json.t
    | Session_updated of A.Json.t
    | Input_audio_buffer_committed of A.Json.t
    | Input_audio_buffer_cleared of { event_id : string; raw : A.Json.t }
    | Input_audio_speech_started of { event_id : string; raw : A.Json.t }
    | Input_audio_speech_stopped of { event_id : string; raw : A.Json.t }
    | Transcription_delta of { event_id : string; item_id : string; content_index : int; delta : string; raw : A.Json.t }
    | Transcription_completed of { event_id : string; item_id : string; content_index : int; transcript : string; languages : language list option; raw : A.Json.t }
    | Transcription_failed of {
        event_id : string;
        item_id : string;
        content_index : int;
        error : A.Json.t;
        raw : A.Json.t;
      }
    | Error of server_error
    | Unknown of { type_ : string; raw : A.Json.t }
  type codec_error = Decode of { message : string; raw_body : A.raw_json option }

  let client_event_json = function
    | Session_update { session; event_id } -> Json.object_ [ ("type", Some (Json.string "session.update")); ("session", Some (session_json session)); ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_append { audio; event_id } -> Json.object_ [ ("type", Some (Json.string "input_audio_buffer.append")); ("audio", Some (Json.string (audio_base64 audio.A.data))); ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_commit { event_id } -> Json.object_ [ ("type", Some (Json.string "input_audio_buffer.commit")); ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_clear { event_id } ->
        Json.object_
          [ ("type", Some (Json.string "input_audio_buffer.clear"));
            ("event_id", Option.map Json.string event_id) ]
  let client_event_to_string event = Json.to_string (client_event_json event)
  let make_decode message raw_body = Decode { message; raw_body }

  let languages raw json =
    match Json.member "languages" json with
    | None -> Ok None
    | Some (`List values) ->
        let rec loop acc = function
          | [] -> Ok (Some (List.rev acc))
          | value :: rest ->
              (match value, Json.string_member "code" value with
               | `Assoc _, Some code -> loop ({ code } :: acc) rest
               | _ ->
                   Error (make_decode
                     "transcription languages must contain objects with string code"
                     (Some raw)))
        in
        loop [] values
    | Some _ ->
        Error
          (make_decode "transcription languages must be an array" (Some raw))

  let decode_server_event raw =
    decode_json raw make_decode @@ fun json ->
    Result.bind (event_type raw make_decode json) @@ function
    | "session.created" -> Ok (Session_created json)
    | "session.updated" -> Ok (Session_updated json)
    | "input_audio_buffer.committed" -> Ok (Input_audio_buffer_committed json)
    | "input_audio_buffer.cleared" ->
        Result.map (fun event_id -> Input_audio_buffer_cleared { event_id; raw = json })
          (required_string raw make_decode "event_id" json)
    | "input_audio_buffer.speech_started" ->
        Result.map (fun event_id -> Input_audio_speech_started { event_id; raw = json })
          (required_string raw make_decode "event_id" json)
    | "input_audio_buffer.speech_stopped" ->
        Result.map (fun event_id -> Input_audio_speech_stopped { event_id; raw = json })
          (required_string raw make_decode "event_id" json)
    | "conversation.item.input_audio_transcription.delta" ->
        Result.bind (required_string raw make_decode "event_id" json) (fun event_id ->
        Result.bind (required_string raw make_decode "item_id" json) (fun item_id ->
        Result.bind (required_int raw make_decode "content_index" json) (fun content_index ->
        Result.map (fun delta -> Transcription_delta
          { event_id; item_id; content_index; delta; raw = json })
          (required_string raw make_decode "delta" json))))
    | "conversation.item.input_audio_transcription.completed" ->
        Result.bind (required_string raw make_decode "item_id" json) (fun item_id ->
        Result.bind (required_int raw make_decode "content_index" json) (fun content_index ->
        Result.bind (required_string raw make_decode "transcript" json) (fun transcript ->
        Result.bind (required_string raw make_decode "event_id" json) (fun event_id ->
        Result.map (fun languages -> Transcription_completed
          { event_id; item_id; content_index;
            transcript; languages; raw = json }) (languages raw json)))))
    | "conversation.item.input_audio_transcription.failed" ->
        Result.bind (required_string raw make_decode "item_id" json) (fun item_id ->
        Result.bind (required_int raw make_decode "content_index" json) (fun content_index ->
        Result.bind (required_string raw make_decode "event_id" json) (fun event_id ->
        match Json.object_member "error" json with
        | Some error -> Ok (Transcription_failed
            { event_id; item_id;
              content_index; error; raw = json })
        | None -> Error (make_decode "transcription failure missing error" (Some raw)))))
    | "error" ->
        Result.bind (required_string raw make_decode "event_id" json) (fun _ ->
        Result.map
          (fun (code, type_, message, event_id, param, detail) ->
            Error
              { code; type_; message; event_id; param; raw = detail;
                full = json })
          (error_fields raw make_decode json))
    | type_ -> Ok (Unknown { type_; raw = json })

  module Codec = struct
    type nonrec session = session
    type nonrec client_event = client_event
    type nonrec server_event = server_event
    type nonrec error = codec_error
    let encode_session session = A.Realtime.Text (client_event_to_string (Session_update { session; event_id = None }))
    let encode_client_event event = A.Realtime.Text (client_event_to_string event)
    let decode_server_event = function
      | A.Realtime.Text raw -> decode_server_event raw
      | A.Realtime.Binary _ -> Error (make_decode "OpenAI Realtime Transcription sent binary WebSocket message" None)
  end
end

module Translation = struct
  type noise_reduction = Disabled | Near_field | Far_field
  type input_transcription = Disabled | Model of string
  type session = { model : string; output_language : string; input_transcription : input_transcription option; noise_reduction : noise_reduction option }
  let session ?input_transcription ?noise_reduction ~model ~output_language () =
    { model; output_language; input_transcription; noise_reduction }

  let transcription_json (value : input_transcription) = match value with Disabled -> `Null | Model model -> Json.object_ [ ("model", Some (Json.string model)) ]
  let noise_json (value : noise_reduction) = match value with
    | Disabled -> `Null
    | Near_field -> Json.object_ [ ("type", Some (Json.string "near_field")) ]
    | Far_field -> Json.object_ [ ("type", Some (Json.string "far_field")) ]

  let session_json session =
    Json.object_ [ ("audio", Some (Json.object_
      [ ("input", if session.input_transcription = None && session.noise_reduction = None then None
           else Some (Json.object_ [ ("transcription", Option.map transcription_json session.input_transcription); ("noise_reduction", Option.map noise_json session.noise_reduction) ]));
        ("output", Some (Json.object_ [ ("language", Some (Json.string session.output_language)) ])) ])) ]
  let session_to_string session = Json.to_string (session_json session)

  type client_event =
    | Session_update of { session : session; event_id : string option }
    | Input_audio_buffer_append of { audio : A.audio; event_id : string option }
    | Session_close of { event_id : string option }
  type server_error = {
    code : string option; type_ : string; message : string;
    event_id : string; param : A.Json.t option;
    raw : A.Json.t; full : A.Json.t;
  }
  type server_event =
    | Session_created of { event_id : string; session : A.Json.t; raw : A.Json.t }
    | Session_updated of { event_id : string; session : A.Json.t; raw : A.Json.t }
    | Session_closed of { event_id : string; raw : A.Json.t }
    | Input_transcript_delta of { event_id : string; delta : string; elapsed_ms : int option; raw : A.Json.t }
    | Output_transcript_delta of { event_id : string; delta : string; elapsed_ms : int option; raw : A.Json.t }
    | Output_audio_delta of { event_id : string; delta : string; channels : int option; elapsed_ms : int option; format : [ `Pcm16 ] option; sample_rate : int option; raw : A.Json.t }
    | Error of server_error
    | Unknown of { type_ : string; raw : A.Json.t }
  type codec_error = Decode of { message : string; raw_body : A.raw_json option }

  let client_event_json = function
    | Session_update { session; event_id } -> Json.object_ [ ("type", Some (Json.string "session.update")); ("session", Some (session_json session)); ("event_id", Option.map Json.string event_id) ]
    | Input_audio_buffer_append { audio; event_id } -> Json.object_ [ ("type", Some (Json.string "session.input_audio_buffer.append")); ("audio", Some (Json.string (audio_base64 audio.A.data))); ("event_id", Option.map Json.string event_id) ]
    | Session_close { event_id } -> Json.object_ [ ("type", Some (Json.string "session.close")); ("event_id", Option.map Json.string event_id) ]
  let client_event_to_string event = Json.to_string (client_event_json event)
  let make_decode message raw_body = Decode { message; raw_body }
  let required_event_id raw json =
    required_string raw make_decode "event_id" json

  let session_event raw json make =
    Result.bind (required_event_id raw json) (fun event_id ->
    match Json.object_member "session" json with
    | Some session -> Ok (make event_id session json)
    | None -> Error (make_decode "Realtime Translation event missing session" (Some raw)))

  let delta_event raw json make =
    Result.bind (required_event_id raw json) (fun event_id ->
    Result.map
      (fun delta -> make event_id delta (Json.int_member "elapsed_ms" json) json)
      (required_string raw make_decode "delta" json))

  let decode_format raw json =
    match Json.member "format" json with
    | None -> Ok None
    | Some (`String "pcm16") -> Ok (Some `Pcm16)
    | Some _ -> Error (make_decode
        "Realtime Translation output audio format must be pcm16" (Some raw))

  let decode_server_event raw =
    decode_json raw make_decode @@ fun json ->
    Result.bind (event_type raw make_decode json) @@ function
    | "session.created" -> session_event raw json (fun event_id session raw -> Session_created { event_id; session; raw })
    | "session.updated" -> session_event raw json (fun event_id session raw -> Session_updated { event_id; session; raw })
    | "session.closed" ->
        Result.map (fun event_id -> Session_closed { event_id; raw = json })
          (required_event_id raw json)
    | "session.input_transcript.delta" -> delta_event raw json (fun event_id delta elapsed_ms raw -> Input_transcript_delta { event_id; delta; elapsed_ms; raw })
    | "session.output_transcript.delta" -> delta_event raw json (fun event_id delta elapsed_ms raw -> Output_transcript_delta { event_id; delta; elapsed_ms; raw })
    | "session.output_audio.delta" ->
        Result.bind (required_event_id raw json) (fun event_id ->
        Result.bind (required_string raw make_decode "delta" json) (fun delta ->
        Result.map (fun format -> Output_audio_delta
          { event_id; delta; channels = Json.int_member "channels" json;
            elapsed_ms = Json.int_member "elapsed_ms" json; format;
            sample_rate = Json.int_member "sample_rate" json; raw = json })
          (decode_format raw json)))
    | "error" ->
        Result.bind (required_event_id raw json) (fun _ ->
          Result.map
            (fun (code, type_, message, event_id, param, detail) ->
              Error
                { code; type_; message; event_id; param; raw = detail;
                  full = json })
            (error_fields raw make_decode json))
    | type_ -> Ok (Unknown { type_; raw = json })

  module Codec = struct
    type nonrec session = session
    type nonrec client_event = client_event
    type nonrec server_event = server_event
    type nonrec error = codec_error
    let encode_session session = A.Realtime.Text (client_event_to_string (Session_update { session; event_id = None }))
    let encode_client_event event = A.Realtime.Text (client_event_to_string event)
    let decode_server_event = function
      | A.Realtime.Text raw -> decode_server_event raw
      | A.Realtime.Binary _ -> Error (make_decode "OpenAI Realtime Translation sent binary WebSocket message" None)
  end
end
