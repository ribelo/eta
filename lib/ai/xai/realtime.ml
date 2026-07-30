module A = Eta_ai
module E = Eta.Effect
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type audio_format = {
  mime : string;
  sample_rate : int;
  channels : int;
}

let pcm ~sample_rate =
  if List.mem sample_rate [ 8000; 16000; 22050; 24000; 32000; 44100; 48000 ]
  then Ok { mime = "audio/pcm"; sample_rate; channels = 1 }
  else
    C.invalid
      "Realtime PCM sample rate must be 8000, 16000, 22050, 24000, 32000, 44100, or 48000"

let pcmu = { mime = "audio/pcmu"; sample_rate = 8000; channels = 1 }
let pcma = { mime = "audio/pcma"; sample_rate = 8000; channels = 1 }
let opus = { mime = "audio/opus"; sample_rate = 24000; channels = 1 }
let audio_format_mime value = value.mime
let audio_format_sample_rate value = value.sample_rate
let audio_format_channels value = value.channels

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
  parameters : A.Json.t;
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

type session = {
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

let validate_turn_detection = function
  | None -> Ok ()
  | Some value ->
      let* () =
        match value.threshold with
        | None -> Ok ()
        | Some threshold ->
            let* threshold = C.finite_float "turn_detection.threshold" threshold in
            if threshold < 0.1 || threshold > 0.9 then
              C.invalid "turn_detection.threshold must be between 0.1 and 0.9"
            else Ok ()
      in
      let validate_ms name = function
        | Some milliseconds when milliseconds < 0 || milliseconds > 10_000 ->
            C.invalid (name ^ " must be between 0 and 10000 milliseconds")
        | _ -> Ok ()
      in
      let* () =
        validate_ms "turn_detection.silence_duration_ms"
          value.silence_duration_ms
      in
      validate_ms "turn_detection.prefix_padding_ms" value.prefix_padding_ms

let validate_tools tools =
  let function_tool = function
    | Function tool ->
        if String.trim tool.name = "" then
          C.invalid "Realtime function tool name must not be empty"
        else Ok ()
    | Web_search tool ->
        if
          tool.allowed_domains <> []
          && tool.excluded_domains <> []
        then
          C.invalid
            "Realtime web_search allowed_domains and excluded_domains are exclusive"
        else if
          List.length tool.allowed_domains > 5
          || List.length tool.excluded_domains > 5
        then C.invalid "Realtime web_search accepts at most 5 domains"
        else Ok ()
    | X_search tool ->
        if tool.allowed_x_handles <> [] && tool.excluded_x_handles <> [] then
          C.invalid
            "Realtime x_search allowed_x_handles and excluded_x_handles are exclusive"
        else if
          List.length tool.allowed_x_handles > 20
          || List.length tool.excluded_x_handles > 20
        then C.invalid "Realtime x_search accepts at most 20 handles"
        else Ok ()
    | File_search tool ->
        if List.length tool.vector_store_ids > 10 then
          C.invalid "Realtime file_search accepts at most 10 collection IDs"
        else Ok ()
    | Mcp tool ->
        if String.trim tool.server_url = "" then
          C.invalid "Realtime MCP server_url must not be empty"
        else if String.trim tool.server_label = "" then
          C.invalid "Realtime MCP server_label must not be empty"
        else Ok ()
  in
  let* () =
    C.result_map_all function_tool tools |> Result.map (fun _ -> ())
  in
  Ok ()

let session ?instructions ?model ?reasoning_effort ?voice ?(tools = [])
    ?turn_detection ?resumption_enabled ?(replace = []) ?input_audio
    ?output_audio () =
  let* () = validate_turn_detection turn_detection in
  let* () = validate_tools tools in
  let* () =
    match input_audio with
    | Some { transcription = Some value; _ } ->
        if List.length value.keyterms > 100 then
          C.invalid "Realtime input transcription accepts at most 100 keyterms"
        else
          C.result_map_all
            (fun term ->
              let* count =
                C.utf8_scalar_count "Realtime input transcription keyterm" term
              in
              if count > 50 then
                C.invalid
                  "Realtime input transcription keyterms must not exceed 50 characters"
              else Ok ())
            value.keyterms
          |> Result.map (fun _ -> ())
    | _ -> Ok ()
  in
  let* () =
    match output_audio with
    | Some { speed = Some speed; _ } ->
        let* speed = C.finite_float "Realtime output speed" speed in
        if speed < 0.7 || speed > 1.5 then
          C.invalid "Realtime output speed must be between 0.7 and 1.5"
        else Ok ()
    | _ -> Ok ()
  in
  Ok
    {
      instructions;
      model;
      reasoning_effort;
      voice;
      tools;
      turn_detection;
      resumption_enabled;
      replace;
      input_audio;
      output_audio;
    }

let format_json value =
  Json.object_
    [
      ("type", Some (Json.string value.mime));
      ("rate", Some (Json.int value.sample_rate));
    ]

let transport_json = function Json -> Json.string "json" | Binary -> Json.string "binary"

let turn_detection_json value =
  if not value.enabled then `Null
  else
    Json.object_
      [
        ("type", Some (Json.string "server_vad"));
        ("threshold", Option.bind value.threshold Json.float);
        ("silence_duration_ms", Option.map Json.int value.silence_duration_ms);
        ("prefix_padding_ms", Option.map Json.int value.prefix_padding_ms);
        ("idle_timeout_ms", Option.map Json.int value.idle_timeout_ms);
      ]

let function_tool_json tool =
  Json.object_
    [
      ("type", Some (Json.string "function"));
      ( "function",
        Some
          (Json.object_
             [
               ("name", Some (Json.string tool.name));
               ("parameters", Some tool.parameters);
               ("description", Option.map Json.string tool.description);
             ]) );
    ]

let strings values =
  if values = [] then None else Some (C.json_string_list values)

let tool_json = function
  | Function tool -> function_tool_json tool
  | Web_search tool ->
      Json.object_
        [
          ("type", Some (Json.string "web_search"));
          ( "location",
            Option.map
              (fun location ->
                Json.object_
                  [
                    ("country", Option.map Json.string location.country);
                    ("city", Option.map Json.string location.city);
                    ("region", Option.map Json.string location.region);
                    ("timezone", Option.map Json.string location.timezone);
                  ])
              tool.location );
          ("allowed_domains", strings tool.allowed_domains);
          ("excluded_domains", strings tool.excluded_domains);
          ( "enable_image_understanding",
            Option.map Json.bool tool.enable_image_understanding );
        ]
  | X_search tool ->
      Json.object_
        [
          ("type", Some (Json.string "x_search"));
          ("allowed_x_handles", strings tool.allowed_x_handles);
          ("excluded_x_handles", strings tool.excluded_x_handles);
          ("from_date", Option.map Json.string tool.from_date);
          ("to_date", Option.map Json.string tool.to_date);
          ( "enable_image_understanding",
            Option.map Json.bool tool.enable_image_understanding );
          ( "enable_video_understanding",
            Option.map Json.bool tool.enable_video_understanding );
        ]
  | File_search tool ->
      Json.object_
        [
          ("type", Some (Json.string "file_search"));
          ( "vector_store_ids",
            Some (C.json_string_list tool.vector_store_ids) );
          ("max_num_results", Option.map Json.int tool.max_num_results);
        ]
  | Mcp tool ->
      Json.object_
        [
          ("type", Some (Json.string "mcp"));
          ("server_url", Some (Json.string tool.server_url));
          ("server_label", Some (Json.string tool.server_label));
          ("server_description", Option.map Json.string tool.server_description);
          ("allowed_tools", strings tool.allowed_tools);
          ("authorization", Option.map Json.string tool.authorization);
          ( "headers",
            if tool.headers = [] then None
            else
              Some
                (Json.object_
                   (List.map
                      (fun (name, value) -> (name, Some (Json.string value)))
                      tool.headers)) );
        ]

let transcription_json value =
  Json.object_
    [
      ("language_hint", Option.map Json.string value.language_hint);
      ("keyterms", strings value.keyterms);
    ]

let input_audio_json (value : input_audio) =
  Json.object_
    [
      ("format", Some (format_json value.format));
      ("transport", Some (transport_json value.transport));
      ("transcription", Option.map transcription_json value.transcription);
    ]

let output_audio_json (value : output_audio) =
  Json.object_
    [
      ("format", Some (format_json value.format));
      ("transport", Some (transport_json value.transport));
      ("speed", Option.bind value.speed Json.float);
    ]

let session_json session =
  Json.object_
    [
      ("instructions", Option.map Json.string session.instructions);
      ("model", Option.map Json.string session.model);
      ( "reasoning",
        Option.map
          (fun effort ->
            Json.object_ [ ("effort", Some (Json.string effort)) ])
          session.reasoning_effort );
      ("voice", Option.map Json.string session.voice);
      ("turn_detection", Option.map turn_detection_json session.turn_detection);
      ( "tools",
        if session.tools = [] then None
        else Some (Json.array (List.map tool_json session.tools)) );
      ( "resumption",
        Option.map
          (fun enabled ->
            Json.object_ [ ("enabled", Some (Json.bool enabled)) ])
          session.resumption_enabled );
      ( "replace",
        if session.replace = [] then None
        else
          Some
            (Json.object_
               (List.map
                  (fun (from_, to_) -> (from_, Some (Json.string to_)))
                  session.replace)) );
      ( "audio",
        if session.input_audio = None && session.output_audio = None then None
        else
          Some
            (Json.object_
               [
                 ( "input",
                   Option.map
                     (fun value -> input_audio_json value)
                     session.input_audio );
                 ( "output",
                   Option.map
                     (fun value -> output_audio_json value)
                     session.output_audio );
               ]) );
    ]

let session_to_string session = Json.to_string (session_json session)

type conversation_item =
  | Message_item of A.Json.t
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
  | Response_create of A.Json.t option
  | Response_cancel of { response_id : string option }

let conversation_item_json = function
  | Message_item json -> json
  | Function_call_output { call_id; output } ->
      Json.object_
        [
          ("type", Some (Json.string "function_call_output"));
          ("call_id", Some (Json.string call_id));
          ("output", Some (Json.string output));
        ]

let client_event_json event =
  match event with
  | Input_audio_binary _ -> None
  | Session_update session ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "session.update"));
          ("session", Some (session_json session));
        ])
  | Input_audio_buffer_append bytes ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "input_audio_buffer.append"));
          ( "audio",
            Some
              (Json.string
                 (Base64.encode_string (Bytes.unsafe_to_string bytes))) );
        ])
  | Input_audio_buffer_commit ->
      Some
        (Json.object_
           [ ("type", Some (Json.string "input_audio_buffer.commit")) ])
  | Input_audio_buffer_clear ->
      Some
        (Json.object_
           [ ("type", Some (Json.string "input_audio_buffer.clear")) ])
  | Conversation_item_create item ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "conversation.item.create"));
          ("item", Some (conversation_item_json item));
        ])
  | Conversation_item_delete { item_id } ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "conversation.item.delete"));
          ("item_id", Some (Json.string item_id));
        ])
  | Conversation_item_truncate { item_id; content_index; audio_end_ms } ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "conversation.item.truncate"));
          ("item_id", Some (Json.string item_id));
          ("content_index", Some (Json.int content_index));
          ("audio_end_ms", Some (Json.int audio_end_ms));
        ])
  | Response_create response ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "response.create"));
          ("response", response);
        ])
  | Response_cancel { response_id } ->
      Some
        (Json.object_
        [
          ("type", Some (Json.string "response.cancel"));
          ("response_id", Option.map Json.string response_id);
        ])

let client_event_message = function
  | Input_audio_binary bytes -> A.Realtime.Binary bytes
  | event ->
      A.Realtime.Text
        (Json.to_string (Option.get (client_event_json event)))

type server_error = {
  code : string option;
  type_ : string option;
  message : string option;
  raw : A.Json.t;
}

type server_event =
  | Session_created of A.Json.t
  | Session_updated of A.Json.t
  | Conversation_created of A.Json.t
  | Conversation_item_added of A.Json.t
  | Conversation_item_deleted of A.Json.t
  | Conversation_item_truncated of A.Json.t
  | Input_audio_speech_started of A.Json.t
  | Input_audio_speech_stopped of A.Json.t
  | Input_audio_committed of A.Json.t
  | Input_audio_cleared of A.Json.t
  | Input_audio_timeout_triggered of A.Json.t
  | Input_audio_transcription_completed of {
      transcript : string option;
      raw : A.Json.t;
    }
  | Input_audio_transcription_updated of {
      transcript : string option;
      raw : A.Json.t;
    }
  | Response_created of A.Json.t
  | Response_output_audio_delta of {
      audio : bytes;
      raw : A.Json.t;
    }
  | Response_output_audio_done of A.Json.t
  | Response_output_audio_transcript_delta of {
      delta : string option;
      raw : A.Json.t;
    }
  | Response_output_audio_transcript_done of A.Json.t
  | Response_text_delta of {
      delta : string option;
      raw : A.Json.t;
    }
  | Response_output_text_delta of {
      delta : string option;
      raw : A.Json.t;
    }
  | Response_done of A.Json.t
  | Dtmf_event_received of A.Json.t
  | Error of server_error
  | Binary_audio of bytes
  | Unknown of {
      type_ : string option;
      raw : A.Json.t;
    }

type codec_error =
  | Invalid_json of string
  | Invalid_base64_audio

let decode_base64 value =
  try Ok (Bytes.of_string (Base64.decode_exn ~pad:true value))
  with _ -> Error Invalid_base64_audio

let transcript json =
  match Json.string_member "transcript" json with
  | Some _ as value -> value
  | None -> Json.string_member "text" json

let decode_json_event json =
  match Json.string_member "type" json with
  | Some "session.created" -> Ok (Session_created json)
  | Some "session.updated" -> Ok (Session_updated json)
  | Some "conversation.created" -> Ok (Conversation_created json)
  | Some "conversation.item.added" -> Ok (Conversation_item_added json)
  | Some "conversation.item.deleted" -> Ok (Conversation_item_deleted json)
  | Some "conversation.item.truncated" -> Ok (Conversation_item_truncated json)
  | Some "input_audio_buffer.speech_started" ->
      Ok (Input_audio_speech_started json)
  | Some "input_audio_buffer.speech_stopped" ->
      Ok (Input_audio_speech_stopped json)
  | Some "input_audio_buffer.committed" -> Ok (Input_audio_committed json)
  | Some "input_audio_buffer.cleared" -> Ok (Input_audio_cleared json)
  | Some "input_audio_buffer.timeout_triggered" ->
      Ok (Input_audio_timeout_triggered json)
  | Some "conversation.item.input_audio_transcription.completed" ->
      Ok
        (Input_audio_transcription_completed
           { transcript = transcript json; raw = json })
  | Some "conversation.item.input_audio_transcription.updated" ->
      Ok
        (Input_audio_transcription_updated
           { transcript = transcript json; raw = json })
  | Some "response.created" -> Ok (Response_created json)
  | Some "response.output_audio.delta" | Some "response.audio.delta" -> (
      match Json.string_member "delta" json with
      | None -> Error Invalid_base64_audio
      | Some value ->
          let* audio = decode_base64 value in
          Ok (Response_output_audio_delta { audio; raw = json }))
  | Some "response.output_audio.done" -> Ok (Response_output_audio_done json)
  | Some "response.output_audio_transcript.delta" ->
      Ok
        (Response_output_audio_transcript_delta
           { delta = Json.string_member "delta" json; raw = json })
  | Some "response.output_audio_transcript.done" ->
      Ok (Response_output_audio_transcript_done json)
  | Some "response.text.delta" ->
      Ok
        (Response_text_delta
           { delta = Json.string_member "delta" json; raw = json })
  | Some "response.output_text.delta" ->
      Ok
        (Response_output_text_delta
           { delta = Json.string_member "delta" json; raw = json })
  | Some "response.done" -> Ok (Response_done json)
  | Some "input_audio_buffer.dtmf_event_received" ->
      Ok (Dtmf_event_received json)
  | Some "error" ->
      let payload =
        Option.value ~default:json (Json.object_member "error" json)
      in
      Ok
        (Error
           {
             code = Json.scalar_string_member "code" payload;
             type_ = Json.scalar_string_member "type" payload;
             message = Json.scalar_string_member "message" payload;
             raw = json;
           })
  | type_ -> Ok (Unknown { type_; raw = json })

let decode_server_event = function
  | A.Realtime.Binary bytes -> Ok (Binary_audio bytes)
  | A.Realtime.Text raw -> (
      match Json.parse raw with
      | Error message -> Error (Invalid_json message)
      | Ok json -> decode_json_event json)

module Codec = struct
  type nonrec session = session
  type nonrec client_event = client_event
  type nonrec server_event = server_event
  type nonrec error = codec_error

  let encode_session session =
    A.Realtime.Text
      (Json.to_string
         (Json.object_
            [
              ("type", Some (Json.string "session.update"));
              ("session", Some (session_json session));
            ]))

  let encode_client_event = client_event_message
  let decode_server_event = decode_server_event
end

type client_secret = string Eta_redacted.t
let client_secret value =
  Eta_redacted.make ~label:"xai_realtime_client_secret" value
let client_secret_redacted value = value

type client_secret_response = {
  value : client_secret;
  expires_at : int64 option;
  raw : A.raw_json;
}

let client_secret_request ?(endpoint = Endpoint.default_inference) ~api_key
    ~expires_after_s () =
  if expires_after_s <= 0 || expires_after_s > 3600 then
    C.invalid "Realtime client-secret TTL must be between 1 and 3600 seconds"
  else
    let base_url = Endpoint.inference_base_url endpoint in
    let json =
      Json.object_
        [
          ( "expires_after",
            Some
              (Json.object_
                 [ ("seconds", Some (Json.int expires_after_s)) ]) );
        ]
    in
    Ok
      (C.json_request ~headers:(C.inference_headers api_key) ~base_url
         ~meth:"POST" ~path:"/v1/realtime/client_secrets" ~json ())

let decode_client_secret raw =
  let* json = C.parse_json raw in
  let* value = C.required_string "value" json in
  Ok
    {
      value = client_secret value;
      expires_at = C.int64_member "expires_at" json;
      raw;
    }

let create_client_secret ?(endpoint = Endpoint.default_inference) client ~api_key
    ~expires_after_s =
  let base_url = Endpoint.inference_base_url endpoint in
  match client_secret_request ~endpoint ~api_key ~expires_after_s () with
  | Error error -> E.fail error
  | Ok request ->
      C.perform_json ~base_url ~operation:"create_realtime_client_secret"
        client request decode_client_secret
