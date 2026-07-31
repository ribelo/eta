(** Full-fidelity buffered OpenAI Chat Completions. *)

module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

let ( let* ) = Result.bind

type modality = Text | Audio

type output_format =
  | Wav
  | Aac
  | Mp3
  | Flac
  | Opus
  | Pcm16

type output_audio = {
  voice : Speech.Voices.t;
  format : output_format;
}

type request = {
  common : A.chat_request;
  modalities : modality list;
  audio : output_audio option;
  store : bool option;
  extra_fields : (string * A.Json.t) list;
}

type function_call = {
  name : string;
  arguments : string;
  raw : A.Json.t;
}

type custom_call = {
  name : string;
  input : string;
  raw : A.Json.t;
}

type tool_call =
  | Function_tool_call of {
      id : string;
      function_ : function_call;
      raw : A.Json.t;
    }
  | Custom_tool_call of {
      id : string;
      custom : custom_call;
      raw : A.Json.t;
    }

type audio = {
  id : string;
  expires_at : int;
  data : string;
  transcript : string;
  raw : A.Json.t;
}

type content_part =
  | Text_part of {
      text : string;
      raw : A.Json.t;
    }
  | Refusal_part of {
      refusal : string;
      raw : A.Json.t;
    }

type message_content =
  | Content_text of string
  | Content_parts of content_part list

type message = {
  role : string;
  content : message_content option;
  refusal : string option;
  annotations : A.Json.t list option;
  function_call : function_call option;
  tool_calls : tool_call list;
  audio : audio option;
  raw : A.Json.t;
}

type choice = {
  index : int;
  message : message;
  finish_reason : string;
  logprobs : logprobs option;
  raw : A.Json.t;
}

and logprobs = {
  content : A.Json.t list option;
  refusal : A.Json.t list option;
  raw : A.Json.t;
}

type prompt_token_details = {
  audio_tokens : int option;
  cached_tokens : int option;
  cache_write_tokens : int option;
  raw : A.Json.t;
}

type completion_token_details = {
  accepted_prediction_tokens : int option;
  audio_tokens : int option;
  reasoning_tokens : int option;
  rejected_prediction_tokens : int option;
  raw : A.Json.t;
}

type usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
  prompt_tokens_details : prompt_token_details option;
  completion_tokens_details : completion_token_details option;
  raw : A.Json.t;
}

type moderation_input_type = Text_input | Image_input

type moderation_result = {
  categories : (string * bool) list;
  category_applied_input_types :
    (string * moderation_input_type list) list;
  category_scores : (string * float) list;
  flagged : bool;
  model : string;
  type_ : string;
  raw : A.Json.t;
}

type moderation_success = {
  model : string;
  results : moderation_result list;
  type_ : string;
  raw : A.Json.t;
}

type moderation_error = {
  code : string;
  message : string;
  type_ : string;
  raw : A.Json.t;
}

type moderation_outcome =
  | Moderation_success of moderation_success
  | Moderation_error of moderation_error

type moderation = {
  input : moderation_outcome;
  output : moderation_outcome;
  raw : A.Json.t;
}

type response = {
  id : string;
  choices : choice list;
  created : int;
  model : string;
  object_ : string;
  service_tier : string option;
  system_fingerprint : string option;
  usage : usage option;
  moderation : moderation option;
  raw : A.Json.t;
  raw_body : A.raw_json;
}

let invalid message = Stdlib.Error (Openai_error.Invalid_request message)
let unsupported message = Stdlib.Error (Openai_error.Unsupported message)

let modality_to_string = function Text -> "text" | Audio -> "audio"

let output_format_to_string = function
  | Wav -> "wav"
  | Aac -> "aac"
  | Mp3 -> "mp3"
  | Flac -> "flac"
  | Opus -> "opus"
  | Pcm16 -> "pcm16"

let owned_fields =
  [
    "model";
    "messages";
    "stream";
    "temperature";
    "max_tokens";
    "tools";
    "response_format";
    "modalities";
    "audio";
    "store";
  ]

let validate_extra extra_fields =
  let rec loop seen = function
    | [] -> Stdlib.Ok ()
    | (name, _) :: _ when List.exists (String.equal name) owned_fields ->
        invalid ("extra field collides with owned field " ^ name)
    | (name, _) :: _ when List.mem name seen ->
        invalid ("extra field repeats name " ^ name)
    | (name, _) :: rest -> loop (name :: seen) rest
  in
  loop [] extra_fields

let validate request =
  let* () =
    match Eta_ai_openai_codec.validate_chat_request request.common with
    | Stdlib.Ok () -> Stdlib.Ok ()
    | Stdlib.Error failure ->
        Stdlib.Error (Openai_error.of_codec_failure failure)
  in
  let names = List.map modality_to_string request.modalities in
  let* () =
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then invalid "Chat Completions modalities must not repeat"
    else Stdlib.Ok ()
  in
  let audio_modality = List.exists (String.equal "audio") names in
  let* () =
    match (audio_modality, request.audio) with
    | true, None ->
        invalid
          "Chat Completions audio modality requires audio output configuration"
    | false, Some _ ->
        invalid
          "Chat Completions audio output configuration requires audio modality"
    | true, Some { voice; format = _ } -> Speech.Voices.validate voice
    | false, None -> Stdlib.Ok ()
  in
  let* () =
    if request.common.stream && audio_modality then
      unsupported
        "streaming Chat Completions audio output is unavailable because OpenAI has not published its audio delta schema"
    else Stdlib.Ok ()
  in
  validate_extra request.extra_fields

let request ~common ?(modalities = []) ?audio ?store ?(extra_fields = []) () =
  let value = { common; modalities; audio; store; extra_fields } in
  Result.map (fun () -> value) (validate value)

let inject_fields request raw =
  match Json.parse raw with
  | Stdlib.Error message ->
      Stdlib.Error (Openai_error.Decode { message; raw_body = Some raw })
  | Stdlib.Ok (`Assoc fields) ->
      let remove_owned (name, _) =
        name <> "modalities" && name <> "audio" && name <> "store"
        && not
             (List.exists
                (fun (extra_name, _) -> String.equal name extra_name)
                request.extra_fields)
      in
      let fields = List.filter remove_owned fields in
      let fields =
        fields
        @
        (match request.modalities with
        | [] -> []
        | values ->
            [
              ( "modalities",
                Json.array
                  (List.map (fun value -> Json.string (modality_to_string value)) values)
              );
            ])
        @
        (match request.audio with
        | None -> []
        | Some audio ->
            [
              ( "audio",
                Json.object_
                  [
                    ("voice", Some (Speech.Voices.to_json audio.voice));
                    ( "format",
                      Some
                        (Json.string
                           (output_format_to_string audio.format)) );
                  ] );
            ])
        @
        (match request.store with
        | None -> []
        | Some value -> [ ("store", Json.bool value) ])
        @ request.extra_fields
      in
      Stdlib.Ok (Json.to_string (`Assoc fields))
  | Stdlib.Ok _ ->
      invalid "Chat Completions encoder did not return a JSON object"

let encode_with_provider ?structured_output provider request =
  let* () = validate request in
  let* () =
    match structured_output with
    | Some _
      when Eta_ai_openai_codec.chat_has_audio request.common
           || Option.is_some request.audio ->
        unsupported
          "Chat Completions audio cannot be combined with structured output"
    | None | Some _ -> Stdlib.Ok ()
  in
  let* raw =
    match provider.A.encode_chat request.common with
    | Stdlib.Ok raw -> Stdlib.Ok raw
    | Stdlib.Error error -> Stdlib.Error (Openai_error.of_ai_error error)
  in
  let* raw =
    match structured_output with
    | None -> Stdlib.Ok raw
    | Some structured_output ->
        Chat_completions.inject_structured_output structured_output raw
  in
  inject_fields request raw

let encode ?structured_output ?provider:custom_provider request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  encode_with_provider ?structured_output provider request

let decode_failure raw_body message =
  Stdlib.Error (Openai_error.Decode { message; raw_body = Some raw_body })

let as_object raw_body label = function
  | `Assoc _ as json -> Stdlib.Ok json
  | _ -> decode_failure raw_body (label ^ " must be an object")

let required_member raw_body label name json =
  match Json.member name json with
  | Some value -> Stdlib.Ok value
  | None -> decode_failure raw_body (label ^ " missing " ^ name)

let required_string raw_body label name json =
  let* value = required_member raw_body label name json in
  match value with
  | `String value -> Stdlib.Ok value
  | _ -> decode_failure raw_body (label ^ "." ^ name ^ " must be a string")

let nullable_string raw_body label name json =
  match Json.member name json with
  | None | Some `Null -> Stdlib.Ok None
  | Some (`String value) -> Stdlib.Ok (Some value)
  | Some _ ->
      decode_failure raw_body (label ^ "." ^ name ^ " must be a string or null")

let optional_nullable_string = nullable_string

let required_nullable_string raw_body label name json =
  match Json.member name json with
  | None -> decode_failure raw_body (label ^ " missing " ^ name)
  | Some `Null -> Stdlib.Ok None
  | Some (`String value) -> Stdlib.Ok (Some value)
  | Some _ ->
      decode_failure raw_body (label ^ "." ^ name ^ " must be a string or null")

let integer = function
  | `Int value when value >= 0 -> Some value
  | `Intlit value -> (
      match int_of_string_opt value with
      | Some parsed when parsed >= 0 && String.equal (string_of_int parsed) value ->
          Some parsed
      | _ -> None)
  | _ -> None

let required_int raw_body label name json =
  let* value = required_member raw_body label name json in
  match integer value with
  | Some value -> Stdlib.Ok value
  | None ->
      decode_failure raw_body
        (label ^ "." ^ name ^ " must be a nonnegative integer")

let optional_int raw_body label name json =
  match Json.member name json with
  | None | Some `Null -> Stdlib.Ok None
  | Some value -> (
      match integer value with
      | Some value -> Stdlib.Ok (Some value)
      | None ->
          decode_failure raw_body
            (label ^ "." ^ name ^ " must be a nonnegative integer"))

let optional_object raw_body label name json =
  match Json.member name json with
  | None | Some `Null -> Stdlib.Ok None
  | Some value ->
      let* value = as_object raw_body (label ^ "." ^ name) value in
      Stdlib.Ok (Some value)

let decode_function_call raw_body json =
  let* raw = as_object raw_body "Chat tool function" json in
  let* name = required_string raw_body "Chat tool function" "name" raw in
  let* arguments =
    required_string raw_body "Chat tool function" "arguments" raw
  in
  Stdlib.Ok { name; arguments; raw }

let decode_custom_call raw_body json =
  let* raw = as_object raw_body "Chat custom tool" json in
  let* name = required_string raw_body "Chat custom tool" "name" raw in
  let* input = required_string raw_body "Chat custom tool" "input" raw in
  Stdlib.Ok { name; input; raw }

let decode_tool_call raw_body json =
  let* raw = as_object raw_body "Chat tool call" json in
  let* id = required_string raw_body "Chat tool call" "id" raw in
  let* type_ = required_string raw_body "Chat tool call" "type" raw in
  match type_ with
  | "function" ->
      let* function_json =
        required_member raw_body "Chat tool call" "function" raw
      in
      let* function_ = decode_function_call raw_body function_json in
      Stdlib.Ok (Function_tool_call { id; function_; raw })
  | "custom" ->
      let* custom_json = required_member raw_body "Chat tool call" "custom" raw in
      let* custom = decode_custom_call raw_body custom_json in
      Stdlib.Ok (Custom_tool_call { id; custom; raw })
  | value ->
      decode_failure raw_body
        ("Chat tool call.type has unsupported discriminator " ^ value)

let decode_list f = function
  | `List values ->
      let rec loop acc = function
        | [] -> Stdlib.Ok (List.rev acc)
        | value :: rest ->
            let* value = f value in
            loop (value :: acc) rest
      in
      loop [] values
  | _ -> invalid_arg "decode_list"

let optional_tool_calls raw_body json =
  match Json.member "tool_calls" json with
  | None | Some `Null -> Stdlib.Ok []
  | Some (`List values) ->
      decode_list (decode_tool_call raw_body) (`List values)
  | Some _ ->
      decode_failure raw_body "Chat message.tool_calls must be an array or null"

let decode_content_part raw_body json =
  let* raw = as_object raw_body "Chat choice.message.content part" json in
  let* type_ =
    required_string raw_body "Chat choice.message.content part" "type" raw
  in
  match type_ with
  | "text" ->
      let* text =
        required_string raw_body "Chat choice.message.content part" "text" raw
      in
      Stdlib.Ok (Text_part { text; raw })
  | "refusal" ->
      let* refusal =
        required_string raw_body "Chat choice.message.content part" "refusal" raw
      in
      Stdlib.Ok (Refusal_part { refusal; raw })
  | value ->
      decode_failure raw_body
        ("Chat choice.message.content part.type has unsupported discriminator "
       ^ value)

let decode_message_content raw_body raw =
  match Json.member "content" raw with
  | None | Some `Null -> Stdlib.Ok None
  | Some (`String value) -> Stdlib.Ok (Some (Content_text value))
  | Some (`List []) ->
      decode_failure raw_body
        "Chat choice.message.content parts must not be empty"
  | Some (`List values) ->
      Result.map
        (fun parts -> Some (Content_parts parts))
        (decode_list (decode_content_part raw_body) (`List values))
  | Some _ ->
      decode_failure raw_body
        "Chat choice.message.content must be a string, array, or null"

let decode_audio raw_body json =
  let* raw = as_object raw_body "Chat message.audio" json in
  let* id = required_string raw_body "Chat message.audio" "id" raw in
  let* expires_at =
    required_int raw_body "Chat message.audio" "expires_at" raw
  in
  let* data = required_string raw_body "Chat message.audio" "data" raw in
  let* transcript =
    required_string raw_body "Chat message.audio" "transcript" raw
  in
  Stdlib.Ok { id; expires_at; data; transcript; raw }

let decode_message raw_body json =
  let* raw = as_object raw_body "Chat choice.message" json in
  let* role = required_string raw_body "Chat choice.message" "role" raw in
  let* content = decode_message_content raw_body raw in
  let* refusal =
    optional_nullable_string raw_body "Chat choice.message" "refusal" raw
  in
  let* annotations =
    match Json.member "annotations" raw with
    | None | Some `Null -> Stdlib.Ok None
    | Some (`List values) -> Stdlib.Ok (Some values)
    | Some _ ->
        decode_failure raw_body
          "Chat choice.message.annotations must be an array or null"
  in
  let* function_call =
    match Json.member "function_call" raw with
    | None | Some `Null -> Stdlib.Ok None
    | Some json ->
        Result.map Option.some (decode_function_call raw_body json)
  in
  let* tool_calls = optional_tool_calls raw_body raw in
  let* audio =
    match Json.member "audio" raw with
    | None | Some `Null -> Stdlib.Ok None
    | Some json -> Result.map Option.some (decode_audio raw_body json)
  in
  Stdlib.Ok
    {
      role;
      content;
      refusal;
      annotations;
      function_call;
      tool_calls;
      audio;
      raw;
    }

let decode_nullable_json_list raw_body label name raw =
  match Json.member name raw with
  | None | Some `Null -> Stdlib.Ok None
  | Some (`List values) -> Stdlib.Ok (Some values)
  | Some _ ->
      decode_failure raw_body (label ^ "." ^ name ^ " must be an array or null")

let decode_logprobs raw_body json =
  let* raw = as_object raw_body "Chat choice.logprobs" json in
  let* content =
    decode_nullable_json_list raw_body "Chat choice.logprobs" "content" raw
  in
  let* refusal =
    decode_nullable_json_list raw_body "Chat choice.logprobs" "refusal" raw
  in
  Stdlib.Ok { content; refusal; raw }

let decode_choice raw_body json =
  let* raw = as_object raw_body "Chat choice" json in
  let* index = required_int raw_body "Chat choice" "index" raw in
  let* message_json = required_member raw_body "Chat choice" "message" raw in
  let* message = decode_message raw_body message_json in
  let* finish_reason =
    required_string raw_body "Chat choice" "finish_reason" raw
  in
  let* logprobs =
    match Json.member "logprobs" raw with
    | None | Some `Null -> Stdlib.Ok None
    | Some value -> Result.map Option.some (decode_logprobs raw_body value)
  in
  Stdlib.Ok { index; message; finish_reason; logprobs; raw }

let decode_prompt_details raw_body json =
  let* raw = as_object raw_body "Chat usage.prompt_tokens_details" json in
  let* audio_tokens =
    optional_int raw_body "Chat usage.prompt_tokens_details" "audio_tokens" raw
  in
  let* cached_tokens =
    optional_int raw_body "Chat usage.prompt_tokens_details" "cached_tokens" raw
  in
  let* cache_write_tokens =
    optional_int raw_body "Chat usage.prompt_tokens_details"
      "cache_write_tokens" raw
  in
  Stdlib.Ok { audio_tokens; cached_tokens; cache_write_tokens; raw }

let decode_completion_details raw_body json =
  let* raw = as_object raw_body "Chat usage.completion_tokens_details" json in
  let* accepted_prediction_tokens =
    optional_int raw_body "Chat usage.completion_tokens_details"
      "accepted_prediction_tokens" raw
  in
  let* audio_tokens =
    optional_int raw_body "Chat usage.completion_tokens_details" "audio_tokens"
      raw
  in
  let* reasoning_tokens =
    optional_int raw_body "Chat usage.completion_tokens_details"
      "reasoning_tokens" raw
  in
  let* rejected_prediction_tokens =
    optional_int raw_body "Chat usage.completion_tokens_details"
      "rejected_prediction_tokens" raw
  in
  Stdlib.Ok
    {
      accepted_prediction_tokens;
      audio_tokens;
      reasoning_tokens;
      rejected_prediction_tokens;
      raw;
    }

let decode_usage raw_body json =
  let* raw = as_object raw_body "Chat usage" json in
  let* prompt_tokens = required_int raw_body "Chat usage" "prompt_tokens" raw in
  let* completion_tokens =
    required_int raw_body "Chat usage" "completion_tokens" raw
  in
  let* total_tokens = required_int raw_body "Chat usage" "total_tokens" raw in
  let* prompt_tokens_details =
    match Json.member "prompt_tokens_details" raw with
    | None | Some `Null -> Stdlib.Ok None
    | Some json -> Result.map Option.some (decode_prompt_details raw_body json)
  in
  let* completion_tokens_details =
    match Json.member "completion_tokens_details" raw with
    | None | Some `Null -> Stdlib.Ok None
    | Some json ->
        Result.map Option.some (decode_completion_details raw_body json)
  in
  Stdlib.Ok
    {
      prompt_tokens;
      completion_tokens;
      total_tokens;
      prompt_tokens_details;
      completion_tokens_details;
      raw;
    }

let required_bool raw_body label name json =
  let* value = required_member raw_body label name json in
  match value with
  | `Bool value -> Stdlib.Ok value
  | _ -> decode_failure raw_body (label ^ "." ^ name ^ " must be a boolean")

let number = function
  | `Int value -> Some (float_of_int value)
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some value when Float.is_finite value -> Some value
      | None | Some _ -> None)
  | `Float value when Float.is_finite value -> Some value
  | _ -> None

let decode_bool_map raw_body label = function
  | `Assoc fields ->
      let rec loop acc = function
        | [] -> Stdlib.Ok (List.rev acc)
        | (name, `Bool value) :: rest -> loop ((name, value) :: acc) rest
        | (name, _) :: _ ->
            decode_failure raw_body
              (label ^ "." ^ name ^ " must be a boolean")
      in
      loop [] fields
  | _ -> decode_failure raw_body (label ^ " must be an object")

let decode_score_map raw_body label = function
  | `Assoc fields ->
      let rec loop acc = function
        | [] -> Stdlib.Ok (List.rev acc)
        | (name, value) :: rest -> (
            match number value with
            | Some value when value >= 0.0 && value <= 1.0 ->
                loop ((name, value) :: acc) rest
            | None ->
                decode_failure raw_body
                  (label ^ "." ^ name
                 ^ " must be a finite number between 0 and 1")
            | Some _ ->
                decode_failure raw_body
                  (label ^ "." ^ name
                 ^ " must be a finite number between 0 and 1"))
      in
      loop [] fields
  | _ -> decode_failure raw_body (label ^ " must be an object")

let decode_moderation_input_type raw_body label = function
  | `String "text" -> Stdlib.Ok Text_input
  | `String "image" -> Stdlib.Ok Image_input
  | _ ->
      decode_failure raw_body
        (label ^ " must contain only text or image")

let decode_applied_input_types raw_body label = function
  | `Assoc fields ->
      let rec fields_loop acc = function
        | [] -> Stdlib.Ok (List.rev acc)
        | (name, `List values) :: rest ->
            let rec values_loop value_acc = function
              | [] ->
                  fields_loop
                    ((name, List.rev value_acc) :: acc)
                    rest
              | value :: values ->
                  let* value =
                    decode_moderation_input_type raw_body
                      (label ^ "." ^ name) value
                  in
                  values_loop (value :: value_acc) values
            in
            values_loop [] values
        | (name, _) :: _ ->
            decode_failure raw_body
              (label ^ "." ^ name ^ " must be an array")
      in
      fields_loop [] fields
  | _ -> decode_failure raw_body (label ^ " must be an object")

let decode_moderation_result raw_body json =
  let label = "Chat moderation result" in
  let* raw = as_object raw_body label json in
  let* categories_json = required_member raw_body label "categories" raw in
  let* categories =
    decode_bool_map raw_body (label ^ ".categories") categories_json
  in
  let* applied_json =
    required_member raw_body label "category_applied_input_types" raw
  in
  let* category_applied_input_types =
    decode_applied_input_types raw_body
      (label ^ ".category_applied_input_types") applied_json
  in
  let* scores_json = required_member raw_body label "category_scores" raw in
  let* category_scores =
    decode_score_map raw_body (label ^ ".category_scores") scores_json
  in
  let* flagged = required_bool raw_body label "flagged" raw in
  let* model = required_string raw_body label "model" raw in
  let* type_ = required_string raw_body label "type" raw in
  let* () =
    if String.equal type_ "moderation_result" then Stdlib.Ok ()
    else decode_failure raw_body (label ^ ".type must be moderation_result")
  in
  Stdlib.Ok
    {
      categories;
      category_applied_input_types;
      category_scores;
      flagged;
      model;
      type_;
      raw;
    }

let decode_moderation_success raw_body raw =
  let label = "Chat moderation results" in
  let* model = required_string raw_body label "model" raw in
  let* results_json = required_member raw_body label "results" raw in
  let* results =
    match results_json with
    | `List values ->
        decode_list (decode_moderation_result raw_body) (`List values)
    | _ -> decode_failure raw_body (label ^ ".results must be an array")
  in
  let* type_ = required_string raw_body label "type" raw in
  let* () =
    if String.equal type_ "moderation_results" then Stdlib.Ok ()
    else decode_failure raw_body (label ^ ".type must be moderation_results")
  in
  Stdlib.Ok (Moderation_success { model; results; type_; raw })

let decode_moderation_error raw_body raw =
  let label = "Chat moderation error" in
  let* code = required_string raw_body label "code" raw in
  let* message = required_string raw_body label "message" raw in
  let* type_ = required_string raw_body label "type" raw in
  Stdlib.Ok (Moderation_error { code; message; type_; raw })

let decode_moderation_outcome raw_body json =
  let* raw = as_object raw_body "Chat moderation outcome" json in
  let* type_ =
    required_string raw_body "Chat moderation outcome" "type" raw
  in
  match type_ with
  | "moderation_results" -> decode_moderation_success raw_body raw
  | "error" -> decode_moderation_error raw_body raw
  | value ->
      decode_failure raw_body
        ("Chat moderation outcome.type has unsupported discriminator " ^ value)

let decode_moderation raw_body json =
  let* raw = as_object raw_body "Chat moderation" json in
  let* input_json = required_member raw_body "Chat moderation" "input" raw in
  let* input = decode_moderation_outcome raw_body input_json in
  let* output_json = required_member raw_body "Chat moderation" "output" raw in
  let* output = decode_moderation_outcome raw_body output_json in
  Stdlib.Ok { input; output; raw }

let decode raw_body =
  match Json.parse raw_body with
  | Stdlib.Error message -> decode_failure raw_body message
  | Stdlib.Ok json ->
      let* raw = as_object raw_body "Chat completion" json in
      let* id = required_string raw_body "Chat completion" "id" raw in
      let* choices_json =
        required_member raw_body "Chat completion" "choices" raw
      in
      let* choices =
        match choices_json with
        | `List [] ->
            decode_failure raw_body
              "Chat completion.choices must contain at least one choice"
        | `List values ->
            decode_list (decode_choice raw_body) (`List values)
        | _ -> decode_failure raw_body "Chat completion.choices must be an array"
      in
      let* created = required_int raw_body "Chat completion" "created" raw in
      let* model = required_string raw_body "Chat completion" "model" raw in
      let* object_ = required_string raw_body "Chat completion" "object" raw in
      let* service_tier =
        optional_nullable_string raw_body "Chat completion" "service_tier" raw
      in
      let* system_fingerprint =
        optional_nullable_string raw_body "Chat completion" "system_fingerprint"
          raw
      in
      let* usage =
        match Json.member "usage" raw with
        | None | Some `Null -> Stdlib.Ok None
        | Some json -> Result.map Option.some (decode_usage raw_body json)
      in
      let* moderation =
        match Json.member "moderation" raw with
        | None | Some `Null -> Stdlib.Ok None
        | Some json -> Result.map Option.some (decode_moderation raw_body json)
      in
      Stdlib.Ok
        {
          id;
          choices;
          created;
          model;
          object_;
          service_tier;
          system_fingerprint;
          usage;
          moderation;
          raw;
          raw_body;
        }

let finish_reason = function
  | "stop" -> A.Stop
  | "length" -> A.Length
  | "tool_calls" -> A.Tool_calls
  | "content_filter" -> A.Content_filter
  | "error" -> A.Error
  | value -> A.Other value

let to_eta_ai_tool_call = function
  | Function_tool_call { id; function_; _ } ->
      {
        A.id;
        name = function_.name;
        arguments_json = function_.arguments;
      }
  | Custom_tool_call { id; custom; _ } ->
      {
        A.id;
        name = custom.name;
        arguments_json = Json.to_string (Json.string custom.input);
      }

let usage_raw (usage : usage) =
  let item name value = (name, string_of_int value) in
  let totals =
    [
      item "prompt_tokens" usage.prompt_tokens;
      item "completion_tokens" usage.completion_tokens;
      item "total_tokens" usage.total_tokens;
    ]
  in
  let prompt_details =
    match usage.prompt_tokens_details with
    | None -> []
    | Some details ->
        List.filter_map
          (fun (name, value) -> Option.map (fun value -> item name value) value)
          [
            ("cached_tokens", details.cached_tokens);
            ("cache_write_tokens", details.cache_write_tokens);
            ("prompt_audio_tokens", details.audio_tokens);
          ]
  in
  let completion_details =
    match usage.completion_tokens_details with
    | None -> []
    | Some details ->
        List.filter_map
          (fun (name, value) -> Option.map (fun value -> item name value) value)
          [
            ("accepted_prediction_tokens", details.accepted_prediction_tokens);
            ("completion_audio_tokens", details.audio_tokens);
            ("reasoning_tokens", details.reasoning_tokens);
            ("rejected_prediction_tokens", details.rejected_prediction_tokens);
          ]
  in
  totals @ prompt_details @ completion_details

let to_eta_ai_usage (usage : usage) =
  let cached =
    Option.bind usage.prompt_tokens_details (fun details -> details.cached_tokens)
  in
  let cache_write =
    Option.bind usage.prompt_tokens_details (fun details ->
        details.cache_write_tokens)
  in
  let reasoning =
    Option.bind usage.completion_tokens_details (fun details ->
        details.reasoning_tokens)
  in
  let output_audio =
    Option.bind usage.completion_tokens_details (fun details ->
        details.audio_tokens)
  in
  let uncached =
    match (cached, cache_write) with
    | Some cached, Some cache_write
      when cached <= usage.prompt_tokens
           && cache_write <= usage.prompt_tokens - cached ->
        Some (usage.prompt_tokens - cached - cache_write)
    | None, _ | _, None | Some _, Some _ -> None
  in
  let text =
    match (reasoning, output_audio) with
    | Some reasoning, Some audio
      when reasoning <= usage.completion_tokens
           && audio <= usage.completion_tokens - reasoning ->
        Some (usage.completion_tokens - reasoning - audio)
    | None, _ | _, None | Some _, Some _ -> None
  in
  {
    A.input_tokens =
      {
        uncached;
        total = Some usage.prompt_tokens;
        cache_read = cached;
        cache_write;
      };
    output_tokens =
      {
        total = Some usage.completion_tokens;
        text;
        reasoning;
      };
    raw = usage_raw usage;
  }

let to_eta_ai (response : response) =
  let choice = List.hd response.choices in
  let message =
    let content =
      match choice.message.content with
      | None | Some (Content_text "") -> []
      | Some (Content_text content) -> [ A.Text content ]
      | Some (Content_parts parts) ->
          List.map
            (function
              | Text_part { text; _ } -> A.Text text
              | Refusal_part { refusal; _ } -> A.Text refusal)
            parts
    in
    let tool_calls =
      List.map to_eta_ai_tool_call choice.message.tool_calls
      @
      match choice.message.function_call with
      | None -> []
      | Some call ->
          [
            {
              A.id = "";
              name = call.name;
              arguments_json = call.arguments;
            };
          ]
    in
    A.Assistant { content; tool_calls }
  in
  {
    A.id = Some response.id;
    model = Some response.model;
    message;
    finish_reasons = [ finish_reason choice.finish_reason ];
    usage = Option.map to_eta_ai_usage response.usage;
    replay_items = [];
    raw = Some response.raw_body;
  }

let audio_bytes (audio : audio) =
  let raw_body = Some (Json.to_string audio.raw) in
  if not (Eta_ai_openai_codec.canonical_padded_base64 audio.data) then
    Stdlib.Error
      (Openai_error.Decode
         {
           message = "Chat completion audio.data is not valid padded base64";
           raw_body;
         })
  else
    try
      Stdlib.Ok
        (Bytes.of_string (Base64.decode_exn ~pad:true audio.data))
    with _ ->
      Stdlib.Error
        (Openai_error.Decode
           {
             message = "Chat completion audio.data is not valid padded base64";
             raw_body;
           })

let http_request ?structured_output ?provider:custom_provider ~api_key request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  match encode_with_provider ?structured_output provider request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (H.Request.make ~headers:(provider.A.auth_headers api_key)
           ~body:(H.Request.Fixed [ Bytes.of_string raw ])
           "POST"
           (Common.join_url provider.base_url provider.chat_path))

let response_attrs response =
  let usage_attrs =
    match response.usage with
    | None -> []
    | Some usage ->
        [
          ("gen_ai.usage.input_tokens", string_of_int usage.prompt_tokens);
          ("gen_ai.usage.output_tokens", string_of_int usage.completion_tokens);
        ]
  in
  [
    ("gen_ai.response.id", response.id);
    ("gen_ai.response.model", response.model);
    ( "gen_ai.response.finish_reasons",
      response.choices
      |> List.map (fun choice -> choice.finish_reason)
      |> String.concat "," );
  ]
  @ usage_attrs

let run ?structured_output ?provider:custom_provider client ~api_key
    chat_request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  Common.run_request
    (http_request ?structured_output ~provider ~api_key chat_request)
    (fun http_request ->
      Common.perform_decoded provider client http_request decode
      |> E.bind (fun response ->
             E.pure response |> E.annotate_all (response_attrs response)))
  |> Common.with_gen_ai_span provider ~operation:"chat"
       ~model:chat_request.common.model

let stream ?structured_output ?provider:custom_provider client ~api_key request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  let request = { request with common = { request.common with stream = true } } in
  match validate request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok () ->
      Common.run_stream provider client request.common
        (http_request ?structured_output ~provider ~api_key request)
