(** Shared OpenRouter provider plumbing: types, attribution/routing, JSON
    helpers, codec wrappers, and the provider builder. Endpoint modules
    layer request builders and runners on top of this. *)

module A = Eta_ai
module Codec = Eta_ai_openai_codec
module H = Eta_http
module Json = A.Json

let ( let* ) = Result.bind

type attribution = {
  referer : string option;
  title : string option;
}

let attribution ?referer ?title () = { referer; title }

type routing = {
  order : string list;
  only_providers : string list;
  ignored_providers : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  sort : string option;
}

type reasoning = {
  effort : string option;
}

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:"openrouter" message

let parse_json raw = Codec.parse_json ~provider:"openrouter" raw

let require_json label raw =
  Codec.schema_value ~provider:"openrouter" label raw

let invalid_routing message =
  Stdlib.Error (A.Unsupported { provider = "openrouter"; feature = message })

let validate_names field values =
  match List.find_opt A.Json_helpers.is_blank values with
  | Some _ -> invalid_routing (field ^ " contains an empty provider name")
  | None -> Stdlib.Ok values

let routing ?(order = []) ?(only_providers = []) ?(ignored_providers = [])
    ?allow_fallbacks ?require_parameters ?sort () =
  match validate_names "order" order with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok order -> (
      match validate_names "only" only_providers with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok only_providers -> (
          match validate_names "ignore" ignored_providers with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok ignored_providers ->
              Stdlib.Ok
                {
                  order;
                  only_providers;
                  ignored_providers;
                  allow_fallbacks;
                  require_parameters;
                  sort;
                }))

let reasoning ?effort () =
  match effort with
  | Some effort when A.Json_helpers.is_blank effort ->
      invalid_routing "reasoning effort is empty"
  | Some effort -> Stdlib.Ok { effort = Some (A.Json_helpers.trim effort) }
  | None -> Stdlib.Ok { effort = None }

let string_array values = Json.array (List.map Json.string values)

let routing_json routing =
  Json.object_
    [
      ( "order",
        if routing.order = [] then None else Some (string_array routing.order) );
      ( "only",
        if routing.only_providers = [] then None
        else Some (string_array routing.only_providers) );
      ( "ignore",
        if routing.ignored_providers = [] then None
        else Some (string_array routing.ignored_providers) );
      ("allow_fallbacks", Option.map Json.bool routing.allow_fallbacks);
      ("require_parameters", Option.map Json.bool routing.require_parameters);
      ("sort", Option.map Json.string routing.sort);
    ]

let reasoning_json reasoning =
  Json.object_ [ ("effort", Option.map Json.string reasoning.effort) ]

let add_object_field ~message name value json =
  match value with
  | None -> Stdlib.Ok json
  | Some value -> (
      match json with
      | `Assoc fields -> Stdlib.Ok (`Assoc (fields @ [ (name, value) ]))
      | _ ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openrouter";
                 message;
                 raw = Some (Json.to_string json);
               }))

let add_routing routing json =
  add_object_field ~message:"Responses encoder did not return a JSON object"
    "provider" (Option.map routing_json routing) json

let add_reasoning reasoning json =
  add_object_field ~message:"Responses encoder did not return a JSON object"
    "reasoning" (Option.map reasoning_json reasoning) json

let encode_responses_tool =
  Codec.tool_json ~schema_value:require_json ~shape:Codec.Responses_tool

let reject_responses_field field = function
  | None -> Stdlib.Ok ()
  | Some _ -> invalid_routing field

let normalize_responses_reasoning request =
  match request.A.Responses.reasoning with
  | None -> Stdlib.Ok request
  | Some reasoning -> (
      match reasoning.effort with
      | None -> Stdlib.Ok request
      | Some effort ->
          Codec.reasoning_level_of_string ~provider:"openrouter" effort
          |> Result.map (fun level ->
                 let effort =
                   match level with
                   | Codec.Off -> "none"
                   | _ -> Codec.reasoning_level_to_string level
                 in
                 {
                   request with
                   A.Responses.reasoning =
                     Some { reasoning with effort = Some effort };
                 }))

let encode_responses_base request =
  let* () =
    reject_responses_field "previous_response_id"
      request.A.Responses.previous_response_id
  in
  let* () =
    match request.store with
    | Some true -> invalid_routing "store=true"
    | None | Some false -> Stdlib.Ok ()
  in
  let* () = reject_responses_field "max_turns" request.max_turns in
  let* () = reject_responses_field "min_p" request.min_p in
  let* () =
    reject_responses_field "reasoning_effort" request.reasoning_effort
  in
  let* () =
    reject_responses_field "reasoning.generate_summary"
      (Option.bind request.reasoning (fun value -> value.generate_summary))
  in
  let* request = normalize_responses_reasoning request in
  Codec.encode_responses ~provider:"openrouter"
    ~encode_tool:encode_responses_tool request

let decorate_responses ?routing ?reasoning request raw =
  match
    ( reasoning,
      request.A.Responses.reasoning,
      request.A.Responses.reasoning_effort )
  with
  | Some _, Some _, _ | Some _, _, Some _ ->
      invalid_routing
        "provider reasoning and Responses request reasoning cannot both be specified"
  | _ -> (
      let* json = parse_json raw in
      match add_routing routing json with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok json -> (
          match add_reasoning reasoning json with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)))

let encode_responses ?routing ?reasoning request =
  let request_to_encode =
    match reasoning with
    | None -> request
    | Some _ -> { request with A.Responses.reasoning = None }
  in
  let* raw = encode_responses_base request_to_encode in
  decorate_responses ?routing ?reasoning request raw

let decode_responses raw = Codec.decode_responses ~provider:"openrouter" raw

let encode_embeddings_json ?routing ?input_type request =
  match Codec.encode_embeddings_json ~provider:"openrouter" request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match
        Codec.optional_non_empty ~provider:"openrouter" "embedding input_type"
              input_type
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok input_type -> (
          match add_routing routing json with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok json ->
              add_object_field
                ~message:"Embeddings encoder did not return a JSON object"
                "input_type" (Option.map Json.string input_type) json))

let encode_embeddings ?routing ?input_type request =
  match encode_embeddings_json ?routing ?input_type request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let openrouter_error_json ?status ?raw json =
  Codec.provider_error_json ?status ?raw ~nested_response_error:true
    ~provider:"openrouter" json

let error_envelope json =
  match Json.object_member "error" json with
  | Some _ -> true
  | None ->
      Option.bind (Json.object_member "response" json) (Json.object_member "error")
      |> Option.is_some

let decode_embeddings raw =
  match parse_json raw with
  | Stdlib.Ok json when error_envelope json ->
      Stdlib.Error (openrouter_error_json ~raw json)
  | _ ->
      Codec.decode_embeddings ~usage_extra_raw_names:[ "cost" ]
        ~provider:"openrouter" raw

let decode_error ~status ~headers raw =
  Codec.decode_error ~nested_response_error:true ~provider:"openrouter" ~status
    ~headers raw

let responses_stream_events raw event_name json =
  Codec.responses_stream_events ~nested_response_error:true
    ~provider:"openrouter" raw event_name json

let decode_stream_event event =
  Codec.decode_stream_event ~nested_response_error:true ~provider:"openrouter"
    event

let attribution_headers = function
  | None -> []
  | Some { referer; title } ->
      (match referer with
      | Some referer -> [ ("HTTP-Referer", referer) ]
      | None -> [])
      @
      match title with
      | Some title -> [ ("X-Title", title) ]
      | None -> []

let auth_headers ?attribution ?(extra_headers = []) api_key =
  H.Core.Header.unsafe_of_list
    ([
       ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
       ("Content-Type", "application/json");
       ("Accept", "application/json");
     ]
    @ attribution_headers attribution @ extra_headers)

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
    text = true;
    image_input = true;
    audio_input = true;
    video_input = false;
    embeddings = true;
    image_generation = true;
    speech = true;
    transcription = true;
    rerank = true;
    video_generation = true;
  }

let provider ?(base_url = "https://openrouter.ai") ?attribution
    ?(extra_headers = []) () =
  {
    A.name = "openrouter";
    base_url;
    chat_path = "/api/v1/responses";
    embeddings_path = Some "/api/v1/embeddings";
    auth_headers = auth_headers ?attribution ~extra_headers;
    capabilities;
    encode_chat =
      (fun _ ->
        Stdlib.Error
          (A.Unsupported
             {
               provider = "openrouter";
               feature =
                 "Chat Completions request cannot be sent to the Responses endpoint";
             }));
    decode_chat = decode_responses;
    encode_embeddings = (fun request -> encode_embeddings request);
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let responses_provider ?base_url ?attribution ?extra_headers () =
  {
    A.transport = provider ?base_url ?attribution ?extra_headers ();
    encode_responses = encode_responses_base;
  }

let default_provider default custom_provider =
  match custom_provider with
  | Some provider -> provider
  | None -> default ()

let post_request = A.post_request
let get_request = A.get_request
let responses_request = A.chat_request
let embeddings_request = A.embeddings_request_with
let run_responses = A.run_responses_request
let run_responses_stream = A.run_responses_stream_request
let run_embeddings = A.run_embeddings_request
let run_raw_decoded = A.run_raw_decoded
let run_binary = A.run_binary_decoded

let with_json_fields = Codec.with_json_fields

let base64_encode = Base64.encode_string
