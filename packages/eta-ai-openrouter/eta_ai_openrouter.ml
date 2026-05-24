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
  schema_json : A.raw_json;
  strict : bool option;
}

let decode_error_result ?raw message =
  Stdlib.Error (A.Decode_error { provider = "openrouter"; message; raw })

let parse_json raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message -> decode_error_result ~raw message

let require_json label raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message ->
      decode_error_result ~raw
        (Printf.sprintf "%s must be valid JSON: %s" label message)

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value:require_json ?strict ~name ~schema_json
    ()

let base_responses_json ?structured_output (request : A.chat_request) =
  let temperature =
    match request.temperature with
    | None -> Stdlib.Ok None
    | Some value -> (
        match Json.float value with
        | Some encoded -> Stdlib.Ok (Some encoded)
        | None ->
            Stdlib.Error
              (A.Unsupported
                 { provider = "openrouter"; feature = "non-finite temperature" }))
  in
  match temperature with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok temperature -> (
      match
        Codec.result_all
          (List.map
             (Codec.tool_json ~schema_value:require_json
                ~shape:Codec.Responses_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools -> (
          match
            Option.fold ~none:(Stdlib.Ok None)
              ~some:(fun output ->
                Codec.structured_output_json ~schema_value:require_json
                  ~shape:Codec.Responses_format output
                |> Result.map (fun value -> Some value))
              structured_output
          with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok text_format ->
              Stdlib.Ok
                (Json.object_
                   [
                     ("model", Some (Json.string request.model));
                     ( "input",
                       Some
                         (request.prompt |> List.concat_map Codec.input_items
                        |> Json.array) );
                     ("stream", Some (Json.bool request.stream));
                     ("temperature", temperature);
                     ( "max_output_tokens",
                       Option.map Json.int request.max_output_tokens );
                     ("tools", if tools = [] then None else Some (Json.array tools));
                     ( "text",
                       Option.map
                         (fun format -> Json.object_ [ ("format", Some format) ])
                         text_format );
                   ])))

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
  match base_responses_json ?structured_output request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match add_routing routing json with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json))

let encode_chat = encode_responses

let int_member first second json =
  match Json.int_member first json with
  | Some _ as value -> value
  | None -> Json.int_member second json

let usage json =
  let input_tokens = int_member "input_tokens" "prompt_tokens" json in
  let output_tokens = int_member "output_tokens" "completion_tokens" json in
  let total_tokens = Json.int_member "total_tokens" json in
  {
    A.input_tokens;
    output_tokens;
    total_tokens;
    raw =
      [
        ("input_tokens", Option.value ~default:"" (Option.map string_of_int input_tokens));
        ( "output_tokens",
          Option.value ~default:"" (Option.map string_of_int output_tokens) );
        ("total_tokens", Option.value ~default:"" (Option.map string_of_int total_tokens));
      ];
  }

let tool_call json =
  match Json.string_member "type" json with
  | Some "function_call" ->
      let id =
        match Json.string_member "call_id" json with
        | Some _ as value -> value
        | None -> Json.string_member "id" json
      in
      let arguments =
        match Json.member "arguments" json with
        | Some (`String arguments) -> Some arguments
        | Some value -> Some (Json.compact value)
        | None -> None
      in
      (match (Json.string_member "name" json, arguments) with
      | Some name, Some arguments_json ->
          Some
            {
              A.id = Option.value ~default:"" id;
              name;
              arguments_json;
            }
      | _ -> None)
  | _ -> None

let output_text item =
  match Json.string_member "type" item with
  | Some "message" | None ->
      Json.array_member "content" item |> Option.value ~default:[]
      |> List.filter_map (fun part ->
             match Json.string_member "text" part with
             | Some text -> Some text
             | None -> Json.string_member "content" part)
  | Some "output_text" -> (
      match Json.string_member "text" item with
      | Some text -> [ text ]
      | None -> [])
  | Some _ -> []

let status_finish json =
  match Json.string_member "status" json with
  | Some "completed" -> [ A.Stop ]
  | Some "incomplete" -> [ A.Length ]
  | Some "failed" -> [ A.Error ]
  | Some status -> [ A.Other status ]
  | None -> []

let decode_responses raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      let output = Json.array_member "output" json |> Option.value ~default:[] in
      let text = output |> List.concat_map output_text |> String.concat "" in
      let tool_calls = output |> List.filter_map tool_call in
      Stdlib.Ok
        {
          A.id = Json.string_member "id" json;
          model = Json.string_member "model" json;
          message =
            A.Assistant
              {
                content = (if String.equal text "" then [] else [ A.Text text ]);
                tool_calls;
              };
          finish_reasons = status_finish json;
          usage = Option.map usage (Json.object_member "usage" json);
          raw = Some raw;
        }

let decode_chat = decode_responses

let error_object json =
  match Json.object_member "error" json with
  | Some _ as value -> value
  | None -> Option.bind (Json.object_member "response" json) (Json.object_member "error")

let openrouter_error_json ?status ?raw json =
  let error = error_object json in
  let message =
    Option.bind error (Json.string_member "message")
    |> Option.value ~default:"provider returned an error"
  in
  let code = Option.bind error (Json.scalar_string_member "code") in
  A.Provider_error
    {
      provider = "openrouter";
      status;
      code;
      message;
      raw;
    }

let openrouter_error ?status raw =
  match parse_json raw with
  | Stdlib.Ok json -> openrouter_error_json ?status ~raw json
  | Stdlib.Error _ ->
      A.Provider_error
        {
          provider = "openrouter";
          status;
          code = None;
          message = "provider returned an error";
          raw = Some raw;
        }

let decode_error ~status ~headers:_ raw =
  openrouter_error ~status raw

let stream_tool_delta json =
  A.Stream_tool_call_delta
    {
      index = Json.int_member "output_index" json;
      id =
        (match Json.string_member "call_id" json with
        | Some _ as value -> value
        | None -> Json.string_member "item_id" json);
      name = None;
      arguments_json_delta =
        Option.value ~default:"" (Json.string_member "delta" json);
    }

let response_event_name event json =
  match event.A.event with
  | Some _ as value -> value
  | None -> Json.string_member "type" json

let responses_stream_events raw event_name json =
  match event_name with
  | Some "response.output_text.delta" -> (
      match Json.string_member "delta" json with
      | Some text -> [ A.Stream_content_delta text ]
      | None -> [])
  | Some "response.function_call_arguments.delta" -> [ stream_tool_delta json ]
  | Some "response.completed" -> [ A.Stream_finish [ A.Stop ]; A.Stream_done ]
  | Some "response.incomplete" -> [ A.Stream_finish [ A.Length ] ]
  | Some "response.failed" ->
      [ A.Stream_error (openrouter_error_json ~raw json) ]
  | _ -> []

let decode_stream_event event =
  let data = String.trim event.A.data in
  if String.equal data "[DONE]" then Stdlib.Ok [ A.Stream_done ]
  else
    match parse_json data with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok json ->
        if Option.is_some (error_object json) then
          Stdlib.Ok [ A.Stream_error (openrouter_error_json ~raw:data json) ]
        else
          Stdlib.Ok
            (responses_stream_events data (response_event_name event json) json)

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
  }

let provider ?(base_url = "https://openrouter.ai") ?attribution
    ?(extra_headers = []) () =
  {
    A.name = "openrouter";
    base_url;
    chat_path = "/api/v1/responses";
    auth_headers = auth_headers ?attribution ~extra_headers;
    capabilities;
    encode_chat = encode_chat;
    decode_chat;
    decode_stream_event;
    decode_error;
  }

let make_request = A.provider_request

let responses_request ?structured_output ?routing ?provider:custom_provider
    ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_chat ?structured_output ?routing request with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let chat_completions_request = responses_request

let perform_chat = A.perform_chat
let perform_stream = A.perform_stream

let responses ?structured_output ?routing ?provider:custom_provider client
    ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match
    responses_request ?structured_output ?routing ~provider ~api_key request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let chat_completions = responses

let stream_responses ?structured_output ?routing ?provider:custom_provider
    client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let request = { request with A.stream = true } in
  match
    responses_request ?structured_output ?routing ~provider ~api_key request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)

let stream_chat_completions = stream_responses
