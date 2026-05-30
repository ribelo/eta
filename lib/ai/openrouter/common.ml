(** Shared OpenRouter provider plumbing: types, attribution/routing, JSON
    helpers, codec wrappers, and the provider builder. Endpoint modules
    layer request builders and runners on top of this. *)

module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

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

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:"openrouter" message

let parse_json raw = Codec.parse_json ~provider:"openrouter" raw

let require_json label raw =
  Codec.schema_value ~provider:"openrouter" label raw

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value:require_json ?strict ~name ~schema_json
    ()

let invalid_routing message =
  Stdlib.Error (A.Unsupported { provider = "openrouter"; feature = message })

let validate_names field values =
  match
    List.find_opt (fun value -> String.equal (String.trim value) "") values
  with
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

let add_routing routing json =
  match routing with
  | None -> Stdlib.Ok json
  | Some routing -> (
      match json with
      | `Assoc fields ->
          Stdlib.Ok (`Assoc (fields @ [ ("provider", routing_json routing) ]))
      | _ ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openrouter";
                 message = "Responses encoder did not return a JSON object";
                 raw = Some (Json.to_string json);
               }))

let encode_responses ?structured_output ?routing request =
  match
    Codec.encode_responses_json ~provider:"openrouter"
      ~schema_value:require_json ?structured_output request
  with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match add_routing routing json with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json))

let decode_responses raw = Codec.decode_responses ~provider:"openrouter" raw

let add_input_type input_type json =
  match input_type with
  | None -> Stdlib.Ok json
  | Some input_type -> (
      match json with
      | `Assoc fields ->
          Stdlib.Ok (`Assoc (fields @ [ ("input_type", Json.string input_type) ]))
      | _ ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openrouter";
                 message = "Embeddings encoder did not return a JSON object";
                 raw = Some (Json.to_string json);
               }))

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
          | Stdlib.Ok json -> add_input_type input_type json))

let encode_embeddings ?routing ?input_type request =
  match encode_embeddings_json ?routing ?input_type request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let decode_embeddings raw =
  Codec.decode_embeddings ~usage_extra_raw_names:[ "cost" ] ~provider:"openrouter"
    raw

let openrouter_error_json ?status ?raw json =
  Codec.provider_error_json ?status ?raw ~nested_response_error:true
    ~provider:"openrouter" json

let openrouter_error ?status raw =
  Codec.provider_error ?status ~nested_response_error:true
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
    audio_input = false;
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
    encode_chat = (fun request -> encode_responses request);
    decode_chat = decode_responses;
    encode_embeddings = (fun request -> encode_embeddings request);
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let make_request = A.provider_request
let perform_chat = A.perform_chat
let perform_stream = A.perform_stream
let perform_embeddings = A.perform_embeddings

let default_provider default custom_provider =
  Option.value ~default:(default ()) custom_provider

let post_request provider ~path ~api_key encode request =
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_post_request provider ~path api_key raw)

let get_request provider ~path ~api_key =
  Stdlib.Ok (A.provider_get_request provider ~path api_key)

let chat_request provider ~api_key encode request =
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)

let embeddings_request provider ~api_key encode request =
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> A.provider_embeddings_request provider api_key raw

let run_request request perform =
  match request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request -> perform http_request

let run_chat provider client chat_request request =
  run_request request (fun http_request ->
      A.with_chat_span provider chat_request
        (perform_chat provider client http_request))

let run_stream provider client chat_request request =
  run_request request (fun http_request ->
      A.with_stream_span provider chat_request
        (perform_stream provider client http_request))

let run_embeddings provider client embedding_request request =
  run_request request (fun http_request ->
      A.with_embeddings_span provider embedding_request
        (perform_embeddings provider client http_request))

let decode_effect decode raw =
  match decode raw with
  | Stdlib.Ok response -> E.pure response
  | Stdlib.Error error -> E.fail error

let run_raw_decoded provider client request decode =
  run_request request (fun http_request ->
      A.perform_raw provider client http_request
      |> E.bind (decode_effect decode))

let run_binary ?max_bytes provider client request decode =
  run_request request (fun http_request ->
      A.perform_binary ?max_bytes provider client http_request |> E.map decode)

let with_json_fields extra fields =
  Json.object_ (fields @ List.map (fun (name, value) -> (name, Some value)) extra)

let base64_encode = Base64.encode_string
