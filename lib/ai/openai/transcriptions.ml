(** OpenAI completed-file transcription and streamed transcription events. *)

module A = Common.A
module E = Eta.Effect
module H = Eta_http
module Json = A.Json
module M = H.Multipart

let ( let* ) = Result.bind
let defer thunk = E.sync thunk |> E.bind Fun.id

let multipart_error ~label error =
  Openai_error.Invalid_request (label ^ " " ^ M.error_message error)

let multipart_source source =
  {
    M.length = A.Audio.known_length source;
    replayability =
      (match A.Audio.replayability source with
      | A.Audio.Replayable -> M.Replayable
      | A.Audio.One_shot -> M.One_shot);
    open_reader = (fun () -> A.Audio.open_pull source);
  }

let multipart_file (upload : A.Audio.upload) =
  M.File
    {
      name = "file";
      filename = upload.filename;
      content_type = upload.content_type;
      data = M.Pull (multipart_source upload.source);
    }

let multipart_text (name, value) = M.Text { name; value }

let check_multipart ~label parts =
  M.make parts
  |> Result.map_error (multipart_error ~label)
  |> Result.map ignore

type model =
  | Whisper_1
  | Gpt_transcribe
  | Gpt_4o_transcribe
  | Gpt_4o_mini_transcribe
  | Gpt_4o_mini_transcribe_2025_12_15
  | Gpt_4o_transcribe_diarize
  | Other of string

type response_format =
  | Json
  | Text
  | Srt
  | Verbose_json
  | Vtt
  | Diarized_json
  | Other_format of string

type include_item = Logprobs | Other_include of string
type timestamp_granularity = Word | Segment | Other_timestamp of string

type vad = {
  prefix_padding_ms : int option;
  silence_duration_ms : int option;
  threshold : float option;
}

type chunking_strategy =
  | Auto
  | Server_vad of vad
  | Other_chunking of A.Json.t

type request = {
  model : model;
  file : A.Audio.upload;
  prompt : string option;
  response_format : response_format option;
  temperature : float option;
  stream : bool option;
  include_ : include_item list;
  timestamp_granularities : timestamp_granularity list;
  chunking_strategy : chunking_strategy option;
  known_speaker_names : string list;
  known_speaker_references : string list;
  keywords : string list;
  language : string option;
  languages : string list;
  extra_fields : (string * string) list;
}

type token_logprob = {
  token : string option;
  bytes : int list option;
  logprob : float option;
  raw : A.Json.t;
}

type token_details = {
  audio_tokens : int option;
  text_tokens : int option;
  raw : A.Json.t;
}

type usage =
  | Tokens of {
      input_tokens : int;
      output_tokens : int;
      total_tokens : int;
      input_token_details : token_details option;
      output_token_details : token_details option;
      raw : A.Json.t;
    }
  | Duration of {
      seconds : float;
      raw : A.Json.t;
    }

type language = {
  code : string;
  raw : A.Json.t;
}

type segment = {
  id : int;
  seek : int;
  start : float;
  end_ : float;
  text : string;
  tokens : int list;
  temperature : float;
  avg_logprob : float;
  compression_ratio : float;
  no_speech_prob : float;
  raw : A.Json.t;
}

type word = {
  word : string;
  start : float;
  end_ : float;
  raw : A.Json.t;
}

type diarized_segment = {
  id : string;
  speaker : string;
  start : float;
  end_ : float;
  text : string;
  type_ : string;
  raw : A.Json.t;
}

type json_result = {
  text : string;
  languages : language list option;
  logprobs : token_logprob list option;
  usage : usage option;
  raw : A.Json.t;
}

type verbose_result = {
  text : string;
  language : string;
  duration : float;
  segments : segment list option;
  words : word list option;
  usage : usage option;
  raw : A.Json.t;
}

type diarized_result = {
  text : string;
  duration : float;
  task : string;
  usage : usage option;
  segments : diarized_segment list;
  raw : A.Json.t;
}

type result =
  | Json_result of json_result
  | Text_result of string
  | Srt_result of string
  | Verbose_json_result of verbose_result
  | Vtt_result of string
  | Diarized_json_result of diarized_result
  | Other_result of {
      format : string;
      body : string;
    }

type event =
  | Text_delta of {
      delta : string;
      logprobs : token_logprob list option;
      segment_id : string option;
      raw : A.Json.t;
    }
  | Text_segment of diarized_segment
  | Text_done of {
      text : string;
      logprobs : token_logprob list option;
      usage : usage option;
      languages : language list option;
      raw : A.Json.t;
    }
  | Unknown of {
      type_ : string;
      raw : A.Json.t;
    }

type configuration = {
  model : model;
  prompt : string option;
  response_format : response_format option;
  temperature : float option;
  stream : bool option;
  include_ : include_item list;
  timestamp_granularities : timestamp_granularity list;
  chunking_strategy : chunking_strategy option;
  known_speaker_names : string list;
  known_speaker_references : string list;
  keywords : string list;
  languages : string list;
  extra_fields : (string * string) list;
}

type request_construction = A.Audio.Speech_to_text.request
type event_stream = event Audio_sse.t

let model_to_string = function
  | Whisper_1 -> "whisper-1"
  | Gpt_transcribe -> "gpt-transcribe"
  | Gpt_4o_transcribe -> "gpt-4o-transcribe"
  | Gpt_4o_mini_transcribe -> "gpt-4o-mini-transcribe"
  | Gpt_4o_mini_transcribe_2025_12_15 ->
      "gpt-4o-mini-transcribe-2025-12-15"
  | Gpt_4o_transcribe_diarize -> "gpt-4o-transcribe-diarize"
  | Other value -> value

let response_format_to_string = function
  | Json -> "json"
  | Text -> "text"
  | Srt -> "srt"
  | Verbose_json -> "verbose_json"
  | Vtt -> "vtt"
  | Diarized_json -> "diarized_json"
  | Other_format value -> value

type canonical_format =
  | Canonical_json
  | Canonical_text
  | Canonical_srt
  | Canonical_verbose_json
  | Canonical_vtt
  | Canonical_diarized_json
  | Canonical_unknown of string

let canonical_format_of_string = function
  | "json" -> Canonical_json
  | "text" -> Canonical_text
  | "srt" -> Canonical_srt
  | "verbose_json" -> Canonical_verbose_json
  | "vtt" -> Canonical_vtt
  | "diarized_json" -> Canonical_diarized_json
  | value -> Canonical_unknown value

let canonical_response_format = function
  | None -> Canonical_json
  | Some format ->
      canonical_format_of_string (response_format_to_string format)

let canonical_format_to_string = function
  | Canonical_json -> "json"
  | Canonical_text -> "text"
  | Canonical_srt -> "srt"
  | Canonical_verbose_json -> "verbose_json"
  | Canonical_vtt -> "vtt"
  | Canonical_diarized_json -> "diarized_json"
  | Canonical_unknown value -> value

let include_to_string = function
  | Logprobs -> "logprobs"
  | Other_include value -> value

let timestamp_to_string = function
  | Word -> "word"
  | Segment -> "segment"
  | Other_timestamp value -> value

let known_models =
  [
    "whisper-1";
    "gpt-transcribe";
    "gpt-4o-transcribe";
    "gpt-4o-mini-transcribe";
    "gpt-4o-mini-transcribe-2025-12-15";
    "gpt-4o-transcribe-diarize";
  ]

let known_model model = List.mem model known_models

let malformed_keyword value =
  List.exists (String.contains value) [ '<'; '>'; '\r'; '\n' ]

let owned_fields =
  [
    "file";
    "model";
    "prompt";
    "response_format";
    "temperature";
    "stream";
    "include";
    "timestamp_granularities";
    "chunking_strategy";
    "known_speaker_names";
    "known_speaker_references";
    "keywords";
    "language";
    "languages";
  ]

let canonical_field name =
  let length = String.length name in
  if length >= 2 && String.sub name (length - 2) 2 = "[]" then
    String.sub name 0 (length - 2)
  else name

let option_exists predicate = function
  | Some value -> predicate value
  | None -> false

let find_substring value needle =
  let value_length = String.length value in
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > value_length then None
    else if String.sub value index needle_length = needle then Some index
    else loop (index + 1)
  in
  loop 0

(* OpenAI's mp3/mpeg/mpga formats use audio/mpeg; mp4/m4a use audio/mp4.
   wav and webm retain their standard subtype. Nonstandard x- aliases are not
   part of the documented upload-format set. *)
let supported_speaker_subtypes = [ "mpeg"; "mp4"; "wav"; "webm" ]

let valid_base64_payload payload =
  let length = String.length payload in
  let rec loop index padding =
    if index = length then padding <= 2
    else
      match payload.[index] with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '+' | '/' when padding = 0 ->
          loop (index + 1) padding
      | '=' -> loop (index + 1) (padding + 1)
      | _ -> false
  in
  length > 0 && length mod 4 = 0 && loop 0 0

let valid_speaker_reference value =
  let prefix = "data:audio/" in
  let marker = ";base64," in
  let prefix_length = String.length prefix in
  if
    String.length value <= prefix_length
    || String.sub value 0 prefix_length <> prefix
  then false
  else
    match find_substring value marker with
    | None -> false
    | Some separator ->
        let subtype_length = separator - prefix_length in
        let payload_start = separator + String.length marker in
        if subtype_length <= 0 || payload_start >= String.length value then false
        else
          let subtype = String.sub value prefix_length subtype_length in
          let payload =
            String.sub value payload_start (String.length value - payload_start)
          in
          List.mem subtype supported_speaker_subtypes
          && valid_base64_payload payload
          &&
          try String.length (Base64.decode_exn ~pad:true payload) > 0
          with _ -> false

let finite_json_number = function
  | `Int value -> Some (float_of_int value)
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some number when Float.is_finite number -> Some number
      | None | Some _ -> None)
  | `Float value when Float.is_finite value -> Some value
  | _ -> None

let json_integer = function
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | _ -> None

let validate_server_vad_json = function
  | `Assoc fields ->
      let member name = List.assoc_opt name fields in
      let* () =
        match member "type" with
        | Some (`String "server_vad") -> Ok ()
        | Some (`String _) ->
            Common.invalid_request
              "chunking strategy is not a server_vad object"
        | None | Some _ ->
            Common.invalid_request
              "chunking server_vad object requires type=server_vad"
      in
      let validate_nonnegative_number name =
        match member name with
        | None -> Ok ()
        | Some value -> (
            match finite_json_number value with
            | Some number when number >= 0.0 -> Ok ()
            | None | Some _ ->
                Common.invalid_request
                  ("chunking " ^ name ^ " must be a finite nonnegative number"))
      in
      let* () = validate_nonnegative_number "prefix_padding_ms" in
      let* () = validate_nonnegative_number "silence_duration_ms" in
      (match member "threshold" with
      | None -> Ok ()
      | Some value -> (
          match finite_json_number value with
          | Some number when number >= 0.0 && number <= 1.0 -> Ok ()
          | None | Some _ ->
              Common.invalid_request
                "chunking threshold must be finite and between 0 and 1"))
  | _ ->
      Common.invalid_request "chunking server_vad strategy must be an object"

let validate_chunking_strategy = function
  | None | Some Auto -> Ok ()
  | Some (Server_vad vad) ->
      if
        option_exists
          (fun value ->
            (not (Float.is_finite value)) || value < 0.0 || value > 1.0)
          vad.threshold
      then
        Common.invalid_request
          "chunking threshold must be finite and between 0 and 1"
      else if
        option_exists (fun value -> value < 0) vad.prefix_padding_ms
        || option_exists (fun value -> value < 0) vad.silence_duration_ms
      then Common.invalid_request "chunking durations must not be negative"
      else Ok ()
  | Some (Other_chunking (`String "auto")) -> Ok ()
  | Some (Other_chunking (`String "server_vad")) ->
      Common.invalid_request
        "chunking server_vad strategy must be an object"
  | Some (Other_chunking (`String value)) ->
      if A.Json_helpers.is_blank value then
        Common.invalid_request "chunking strategy type must not be empty"
      else Ok ()
  | Some (Other_chunking (`Assoc fields as json)) -> (
      match List.assoc_opt "type" fields with
      | Some (`String "server_vad") -> validate_server_vad_json json
      | Some (`String "auto") ->
          Common.invalid_request
            "chunking auto strategy must be the string auto"
      | Some (`String value) ->
          if A.Json_helpers.is_blank value then
            Common.invalid_request "chunking strategy type must not be empty"
          else Ok ()
      | None | Some _ ->
          Common.invalid_request
            "chunking strategy object requires a string type")
  | Some (Other_chunking _) ->
      Common.invalid_request
        "chunking strategy must be a string or typed JSON object"

let validate (request : request) =
  let model = model_to_string request.model in
  let canonical_format = canonical_response_format request.response_format in
  let format = canonical_format_to_string canonical_format in
  let diarize = String.equal model "gpt-4o-transcribe-diarize" in
  let whisper = String.equal model "whisper-1" in
  let plural = String.equal model "gpt-transcribe" in
  if A.Json_helpers.is_blank model then
    Common.invalid_request "transcription model must not be empty"
  else if A.Json_helpers.is_blank format then
    Common.invalid_request "transcription response format must not be empty"
  else
    let* () =
      check_multipart ~label:"transcription" [ multipart_file request.file ]
    in
    let* () =
      if A.Json_helpers.is_blank request.file.filename then
        Common.invalid_request "transcription filename must not be empty"
      else if A.Json_helpers.is_blank request.file.content_type then
        Common.invalid_request "transcription content type must not be empty"
      else Ok ()
    in
    let* () =
      match request.extra_fields with
      | [] -> Ok ()
      | fields ->
          check_multipart ~label:"transcription"
            (List.map multipart_text fields @ [ multipart_file request.file ])
    in
    let* () =
      Audio_upload_limit.validate ~label:"transcription" request.file.source
    in
    let* () =
      match request.temperature with
      | Some value
        when (not (Float.is_finite value)) || value < 0.0 || value > 1.0 ->
          Common.invalid_request
            "transcription temperature must be finite and between 0 and 1"
      | None | Some _ -> Ok ()
    in
    let* () =
      if Option.is_some request.language && request.languages <> [] then
        Common.invalid_request
          "transcription language and languages are mutually exclusive"
      else if plural && Option.is_some request.language then
        Common.invalid_request
          "gpt-transcribe uses languages instead of language"
      else if
        known_model model && not plural && request.languages <> []
      then
        Common.invalid_request
          "transcription languages are supported only by gpt-transcribe"
      else Ok ()
    in
    let* () =
      if List.exists malformed_keyword request.keywords then
        Common.invalid_request
          "transcription keywords must be one line and contain no '<' or '>'"
      else if
        known_model model && not plural && request.keywords <> []
      then
        Common.invalid_request
          "transcription keywords are supported only by gpt-transcribe"
      else Ok ()
    in
    let* () =
      if diarize && Option.is_some request.prompt then
        Common.invalid_request
          "transcription prompt is not supported by gpt-4o-transcribe-diarize"
      else Ok ()
    in
    let* () =
      if
        List.mem model
          [
            "gpt-transcribe";
            "gpt-4o-transcribe";
            "gpt-4o-mini-transcribe";
            "gpt-4o-mini-transcribe-2025-12-15";
          ]
        && canonical_format <> Canonical_json
      then
        Common.invalid_request
          "selected transcription model supports only response_format=json"
      else if
        diarize
        && not
             (List.mem canonical_format
                [
                  Canonical_json;
                  Canonical_text;
                  Canonical_diarized_json;
                ])
      then
        Common.invalid_request
          "gpt-4o-transcribe-diarize supports json, text, or diarized_json"
      else if whisper && canonical_format = Canonical_diarized_json then
        Common.invalid_request
          "whisper-1 does not support response_format=diarized_json"
      else Ok ()
    in
    let* () =
      if
        request.timestamp_granularities <> []
        && canonical_format <> Canonical_verbose_json
      then
        Common.invalid_request
          "timestamp granularities require response_format=verbose_json"
      else if
        request.timestamp_granularities <> [] && known_model model
        && not whisper
      then
        Common.invalid_request
          "timestamp granularities are supported only by whisper-1"
      else Ok ()
    in
    let has_logprobs =
      List.exists
        (fun item -> String.equal (include_to_string item) "logprobs")
        request.include_
    in
    let* () =
      if has_logprobs && canonical_format <> Canonical_json then
        Common.invalid_request
          "include=logprobs requires response_format=json"
      else if
        has_logprobs && known_model model
        && not
             (List.mem model
                [
                  "gpt-4o-transcribe";
                  "gpt-4o-mini-transcribe";
                  "gpt-4o-mini-transcribe-2025-12-15";
                ])
      then
        Common.invalid_request
          "include=logprobs is not supported by the selected model"
      else if diarize && request.include_ <> [] then
        Common.invalid_request
          "include is not supported by gpt-4o-transcribe-diarize"
      else Ok ()
    in
    let* () =
      if
        (request.known_speaker_names = [])
        <> (request.known_speaker_references = [])
        || List.length request.known_speaker_names
           <> List.length request.known_speaker_references
      then
        Common.invalid_request
          "known speaker names and references must have equal cardinality"
      else if List.length request.known_speaker_names > 4 then
        Common.invalid_request "at most four known speakers are supported"
      else if
        List.exists A.Json_helpers.is_blank request.known_speaker_names
      then Common.invalid_request "known speaker names must not be empty"
      else if
        not (List.for_all valid_speaker_reference request.known_speaker_references)
      then
        Common.invalid_request
          "known speaker references must be nonempty base64 audio data URLs"
      else if
        known_model model && not diarize
        && request.known_speaker_names <> []
      then
        Common.invalid_request
          "known speakers are supported only by gpt-4o-transcribe-diarize"
      else Ok ()
    in
    let* () = validate_chunking_strategy request.chunking_strategy in
    let* () =
      if whisper && request.stream = Some true then
        Common.invalid_request "streaming is not supported by whisper-1"
      else Ok ()
    in
    let* () =
      if
        diarize && request.stream = Some true
        && canonical_format <> Canonical_diarized_json
      then
        Common.invalid_request
          "streamed diarization requires response_format=diarized_json"
      else Ok ()
    in
    match
      List.find_opt
        (fun (name, _) ->
          List.mem (canonical_field name) owned_fields)
        request.extra_fields
    with
    | Some (name, _) ->
        Common.invalid_request
          ("extra field collides with owned field " ^ name)
    | None -> Ok ()

let request ~model ~file ?prompt ?response_format ?temperature ?stream
    ?(include_ = []) ?(timestamp_granularities = []) ?chunking_strategy
    ?(known_speaker_names = []) ?(known_speaker_references = [])
    ?(keywords = []) ?language ?(languages = []) ?(extra_fields = []) () =
  let request =
    {
      model;
      file;
      prompt;
      response_format;
      temperature;
      stream;
      include_;
      timestamp_granularities;
      chunking_strategy;
      known_speaker_names;
      known_speaker_references;
      keywords;
      language;
      languages;
      extra_fields;
    }
  in
  Result.map (fun () -> request) (validate request)

let of_eta_ai request = request

let configure configuration (construction : request_construction) =
  request ~model:configuration.model ~file:construction.upload
    ?prompt:configuration.prompt ?response_format:configuration.response_format
    ?temperature:configuration.temperature ?stream:configuration.stream
    ~include_:configuration.include_
    ~timestamp_granularities:configuration.timestamp_granularities
    ?chunking_strategy:configuration.chunking_strategy
    ~known_speaker_names:configuration.known_speaker_names
    ~known_speaker_references:configuration.known_speaker_references
    ~keywords:configuration.keywords ?language:construction.language
    ~languages:configuration.languages ~extra_fields:configuration.extra_fields ()

let to_eta_ai = function
  | Json_result result ->
      {
        A.Audio.Speech_to_text.text = Some result.text;
        language = None;
        duration_s = None;
      }
  | Verbose_json_result result ->
      {
        text = Some result.text;
        language = Some result.language;
        duration_s = Some result.duration;
      }
  | Diarized_json_result result ->
      {
        text = Some result.text;
        language = None;
        duration_s = Some result.duration;
      }
  | Text_result text | Srt_result text | Vtt_result text ->
      { text = Some text; language = None; duration_s = None }
  | Other_result _ ->
      { text = None; language = None; duration_s = None }

let decode_error raw message =
  Error (Openai_error.Decode { message; raw_body = Some raw })

let as_string = function `String value -> Some value | _ -> None
let as_int = json_integer
let as_float = finite_json_number
let as_object = function `Assoc _ as value -> Some value | _ -> None
let as_list = function `List values -> Some values | _ -> None

let required name decode raw json =
  match Json.member name json with
  | None -> decode_error raw ("missing transcription " ^ name)
  | Some value -> (
      match decode value with
      | Some value -> Ok value
      | None -> decode_error raw ("invalid transcription " ^ name))

let optional name decode raw json =
  match Json.member name json with
  | None -> Ok None
  | Some value -> (
      match decode value with
      | Some value -> Ok (Some value)
      | None -> decode_error raw ("invalid transcription " ^ name))

let rec decode_list decode raw acc = function
  | [] -> Ok (List.rev acc)
  | value :: rest ->
      let* value = decode raw value in
      decode_list decode raw (value :: acc) rest

let list decode raw values = decode_list decode raw [] values

let nonnegative_int raw label value =
  match as_int value with
  | Some value when value >= 0 -> Ok value
  | None | Some _ ->
      decode_error raw (label ^ " must be a nonnegative integer")

let token_details raw json =
  let* audio_tokens =
    match Json.member "audio_tokens" json with
    | None -> Ok None
    | Some value ->
        Result.map Option.some
          (nonnegative_int raw "audio_tokens" value)
  in
  let* text_tokens =
    match Json.member "text_tokens" json with
    | None -> Ok None
    | Some value ->
        Result.map Option.some
          (nonnegative_int raw "text_tokens" value)
  in
  Ok { audio_tokens; text_tokens; raw = json }

let optional_token_details name raw json =
  let* details = optional name as_object raw json in
  match details with
  | None -> Ok None
  | Some details ->
      Result.map Option.some (token_details raw details)

let token_usage raw json =
  let* type_ = required "type" as_string raw json in
  if not (String.equal type_ "tokens") then
    decode_error raw "transcription usage type must be tokens"
  else
    let* input_tokens =
      match Json.member "input_tokens" json with
      | Some value ->
          nonnegative_int raw "input_tokens" value
      | None -> decode_error raw "missing transcription input_tokens"
    in
    let* output_tokens =
      match Json.member "output_tokens" json with
      | Some value ->
          nonnegative_int raw "output_tokens" value
      | None -> decode_error raw "missing transcription output_tokens"
    in
    let* total_tokens =
      match Json.member "total_tokens" json with
      | Some value ->
          nonnegative_int raw "total_tokens" value
      | None -> decode_error raw "missing transcription total_tokens"
    in
    let* input_token_details =
      optional_token_details "input_token_details" raw json
    in
    let* output_token_details =
      optional_token_details "output_token_details" raw json
    in
    Ok
      (Tokens
         {
           input_tokens;
           output_tokens;
           total_tokens;
           input_token_details;
           output_token_details;
           raw = json;
         })

let duration_usage raw json =
  let* type_ = required "type" as_string raw json in
  if not (String.equal type_ "duration") then
    decode_error raw "transcription usage type must be duration"
  else
    let* seconds = required "seconds" as_float raw json in
    if seconds < 0.0 then
      decode_error raw "transcription usage seconds must not be negative"
    else Ok (Duration { seconds; raw = json })

let usage_union raw json =
  let* type_ = required "type" as_string raw json in
  match type_ with
  | "tokens" -> token_usage raw json
  | "duration" -> duration_usage raw json
  | value ->
      decode_error raw ("unknown transcription usage type " ^ value)

let optional_usage decode raw json =
  let* usage = optional "usage" as_object raw json in
  match usage with
  | None -> Ok None
  | Some usage -> Result.map Option.some (decode raw usage)

let token_logprob raw value =
  let* json =
    match as_object value with
    | Some json -> Ok json
    | None -> decode_error raw "transcription logprob must be an object"
  in
  let* token = optional "token" as_string raw json in
  let* bytes =
    let* values = optional "bytes" as_list raw json in
    match values with
    | None -> Ok None
    | Some values ->
        Result.map Option.some
          (list
             (fun raw value ->
               match as_int value with
               | Some value when value >= 0 && value <= 255 -> Ok value
               | None | Some _ ->
                   decode_error raw
                     "transcription logprob byte must be an integer from 0 to 255")
             raw values)
  in
  let* logprob = optional "logprob" as_float raw json in
  Ok { token; bytes; logprob; raw = json }

let language raw value =
  let* json =
    match as_object value with
    | Some json -> Ok json
    | None -> decode_error raw "transcription language must be an object"
  in
  let* code = required "code" as_string raw json in
  Ok { code; raw = json }

let optional_list name decode raw json =
  let* values = optional name as_list raw json in
  match values with
  | None -> Ok None
  | Some values ->
      Result.map Option.some (list decode raw values)

let integer_tokens raw json =
  let* values = required "tokens" as_list raw json in
  list
    (fun raw value ->
      match as_int value with
      | Some value -> Ok value
      | None ->
          decode_error raw "transcription token ID must be an integer")
    raw values

let segment raw value =
  let* json =
    match as_object value with
    | Some json -> Ok json
    | None -> decode_error raw "transcription segment must be an object"
  in
  let* id = required "id" as_int raw json in
  let* seek = required "seek" as_int raw json in
  let* start = required "start" as_float raw json in
  let* end_ = required "end" as_float raw json in
  let* text = required "text" as_string raw json in
  let* tokens = integer_tokens raw json in
  let* temperature = required "temperature" as_float raw json in
  let* avg_logprob = required "avg_logprob" as_float raw json in
  let* compression_ratio = required "compression_ratio" as_float raw json in
  let* no_speech_prob = required "no_speech_prob" as_float raw json in
  Ok
    {
      id;
      seek;
      start;
      end_;
      text;
      tokens;
      temperature;
      avg_logprob;
      compression_ratio;
      no_speech_prob;
      raw = json;
    }

let word raw value =
  let* json =
    match as_object value with
    | Some json -> Ok json
    | None -> decode_error raw "transcription word must be an object"
  in
  let* word = required "word" as_string raw json in
  let* start = required "start" as_float raw json in
  let* end_ = required "end" as_float raw json in
  Ok { word; start; end_; raw = json }

let diarized_segment raw value =
  let* json =
    match as_object value with
    | Some json -> Ok json
    | None ->
        decode_error raw "diarized transcription segment must be an object"
  in
  let* id = required "id" as_string raw json in
  let* speaker = required "speaker" as_string raw json in
  let* start = required "start" as_float raw json in
  let* end_ = required "end" as_float raw json in
  let* text = required "text" as_string raw json in
  let* type_ = required "type" as_string raw json in
  if not (String.equal type_ "transcript.text.segment") then
    decode_error raw "invalid diarized transcription segment type"
  else Ok { id; speaker; start; end_; text; type_; raw = json }

let object_body raw =
  match Json.parse raw with
  | Ok (`Assoc _ as json) -> Ok json
  | Ok _ ->
      decode_error raw "transcription response must be a JSON object"
  | Error message -> decode_error raw message

let decode_json raw =
  let* json = object_body raw in
  let* text = required "text" as_string raw json in
  let* languages = optional_list "languages" language raw json in
  let* logprobs = optional_list "logprobs" token_logprob raw json in
  let* usage = optional_usage usage_union raw json in
  Ok (Json_result { text; languages; logprobs; usage; raw = json })

let decode_verbose raw =
  let* json = object_body raw in
  let* text = required "text" as_string raw json in
  let* language = required "language" as_string raw json in
  let* duration = required "duration" as_float raw json in
  let* segments = optional_list "segments" segment raw json in
  let* words = optional_list "words" word raw json in
  let* usage = optional_usage duration_usage raw json in
  Ok
    (Verbose_json_result
       { text; language; duration; segments; words; usage; raw = json })

let decode_diarized raw =
  let* json = object_body raw in
  let* text = required "text" as_string raw json in
  let* duration = required "duration" as_float raw json in
  let* task = required "task" as_string raw json in
  if not (String.equal task "transcribe") then
    decode_error raw "invalid diarized transcription task"
  else
    let* values = required "segments" as_list raw json in
    let* segments = list diarized_segment raw values in
    let* usage = optional_usage usage_union raw json in
    Ok
      (Diarized_json_result
         { text; duration; task; usage; segments; raw = json })

let decode_response response_format raw =
  match canonical_response_format response_format with
  | Canonical_json -> decode_json raw
  | Canonical_text -> Ok (Text_result raw)
  | Canonical_srt -> Ok (Srt_result raw)
  | Canonical_verbose_json -> decode_verbose raw
  | Canonical_vtt -> Ok (Vtt_result raw)
  | Canonical_diarized_json -> decode_diarized raw
  | Canonical_unknown format ->
      Ok (Other_result { format; body = raw })

let chunking_string = function
  | Auto -> "auto"
  | Server_vad vad ->
      Json.object_
        [
          ("type", Some (Json.string "server_vad"));
          ("prefix_padding_ms", Option.map Json.int vad.prefix_padding_ms);
          ("silence_duration_ms", Option.map Json.int vad.silence_duration_ms);
          ("threshold", Option.bind vad.threshold Json.float);
        ]
      |> Json.compact
  | Other_chunking (`String value) -> value
  | Other_chunking json -> Json.compact json

let multipart_fields (request : request) =
  let optional name encode value =
    Option.to_list
      (Option.map (fun value -> (name, encode value)) value)
  in
  [ ("model", model_to_string request.model) ]
  @ optional "prompt" Fun.id request.prompt
  @ optional "response_format" response_format_to_string
      request.response_format
  @ optional "temperature" (Printf.sprintf "%.17g") request.temperature
  @ optional "stream" string_of_bool request.stream
  @ List.map
      (fun item -> ("include[]", include_to_string item))
      request.include_
  @ List.map
      (fun granularity ->
        ("timestamp_granularities[]", timestamp_to_string granularity))
      request.timestamp_granularities
  @ optional "chunking_strategy" chunking_string request.chunking_strategy
  @ List.map
      (fun name -> ("known_speaker_names[]", name))
      request.known_speaker_names
  @ List.map
      (fun reference -> ("known_speaker_references[]", reference))
      request.known_speaker_references
  @ List.map (fun keyword -> ("keywords[]", keyword)) request.keywords
  @ optional "language" Fun.id request.language
  @ List.map (fun language -> ("languages[]", language)) request.languages
  @ request.extra_fields

let http_request ?provider:custom_provider ~api_key (request : request) =
  let provider = Common.default_provider Common.provider custom_provider in
  let* () = validate request in
  let* multipart =
    M.make
      (List.map multipart_text (multipart_fields request)
      @ [ multipart_file request.file ])
    |> Result.map_error (multipart_error ~label:"transcription")
  in
  let headers =
    provider.A.auth_headers api_key
    |> H.Core.Header.remove "accept"
    |> H.Core.Header.remove "content-type"
    |> H.Core.Header.remove "content-length"
    |> H.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ multipart.boundary)
  in
  let http_request =
    H.Request.make ~headers ~body:multipart.body "POST"
      (Common.join_url provider.A.base_url "/v1/audio/transcriptions")
  in
  if request.stream = Some true then
    Ok
      {
        http_request with
        headers =
          Eta_http.Core.Header.unsafe_add "Accept" "text/event-stream"
            http_request.headers;
      }
  else Ok http_request

let operation_mismatch (request : request) expected =
  match request.stream, expected with
  | Some true, `Buffered ->
      Common.invalid_request "stream=true requires stream_events"
  | (None | Some false), `Events ->
      Common.invalid_request "stream_events requires stream=true"
  | (None | Some false), `Buffered | Some true, `Events -> Ok ()

let span_attrs (request : request) stream =
  [
    ( "eta_ai.request.response_format",
      canonical_response_format request.response_format
      |> canonical_format_to_string );
    ("eta_ai.request.stream", string_of_bool stream);
  ]

let create ?provider:custom_provider client ~api_key (request : request) =
  let provider = Common.default_provider Common.provider custom_provider in
  let model = model_to_string request.model in
  (match operation_mismatch request `Buffered with
  | Error error -> E.fail error
  | Ok () ->
      defer (fun () ->
          Common.run_raw_decoded ~max_bytes:max_int provider client
            (http_request ~provider ~api_key request)
            (decode_response request.response_format)))
  |> Common.with_provider_span provider ~operation:"transcription.create" ~model
       ~attrs:(span_attrs request false)

let decode_event raw json =
  let* type_ = required "type" as_string raw json in
  match type_ with
  | "transcript.text.delta" ->
      let* delta = required "delta" as_string raw json in
      let* logprobs = optional_list "logprobs" token_logprob raw json in
      let* segment_id = optional "segment_id" as_string raw json in
      Ok (Text_delta { delta; logprobs; segment_id; raw = json })
  | "transcript.text.segment" ->
      Result.map
        (fun segment -> Text_segment segment)
        (diarized_segment raw json)
  | "transcript.text.done" ->
      let* text = required "text" as_string raw json in
      let* logprobs = optional_list "logprobs" token_logprob raw json in
      let* usage = optional_usage token_usage raw json in
      let* languages = optional_list "languages" language raw json in
      Ok (Text_done { text; logprobs; usage; languages; raw = json })
  | type_ -> Ok (Unknown { type_; raw = json })

let default_max_buffer_bytes = Audio_sse.default_max_buffer_bytes
let default_max_json_bytes = Audio_sse.default_max_json_bytes
let default_max_pending_events = Audio_sse.default_max_pending_events

let read_event stream =
  Audio_sse.read stream ~operation:"transcription.read_event"

let close_events stream =
  Audio_sse.close stream ~operation:"transcription.close_events"

let stream_events ?(max_buffer_bytes = default_max_buffer_bytes)
    ?(max_json_bytes = default_max_json_bytes)
    ?(max_pending_events = default_max_pending_events) ?provider:custom_provider
    client ~api_key (request : request) =
  let provider = Common.default_provider Common.provider custom_provider in
  let model = model_to_string request.model in
  let attrs = span_attrs request true in
  (match
     Audio_sse.validate_bounds ~kind:"transcription SSE" ~max_buffer_bytes
       ~max_json_bytes ~max_pending_events
   with
  | Error error -> E.fail error
  | Ok () -> (
      match operation_mismatch request `Events with
      | Error error -> E.fail error
      | Ok () ->
          Audio_sse.allocate ~kind:"transcription SSE" ~max_buffer_bytes
            ~max_json_bytes
          |> E.bind (fun storage ->
                 Common.run_request
                   (http_request ~provider ~api_key request)
                   (fun http_request ->
                     Speech.perform_stream client http_request (fun body ->
                         Audio_sse.make ~provider ~model
                           ~kind:"transcription SSE" ~attrs ~body
                           ~decode:decode_event ~max_buffer_bytes ~max_json_bytes
                           ~max_pending_events storage)))))
  |> Common.with_provider_span provider
       ~operation:"transcription.stream_events" ~model ~attrs
