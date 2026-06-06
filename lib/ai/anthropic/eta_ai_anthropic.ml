module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

type prompt_cache = {
  beta_header : string;
  cache_system : bool;
}

let prompt_cache ?(beta_header = "prompt-caching-2024-07-31")
    ?(cache_system = false) () =
  { beta_header; cache_system }

let decode_error_result ?raw message =
  A.Json_helpers.decode_error_result ?raw ~provider:"anthropic" message

let parse_raw_json label raw =
  A.Json_helpers.schema_value ~provider:"anthropic" label raw

let result_all = A.Json_helpers.result_all
let result_map_all = A.Json_helpers.result_map_all
let ( let* ) = Result.bind

let contents_text contents =
  let rec loop acc = function
    | [] -> Stdlib.Ok (String.concat "" (List.rev acc))
    | A.Text text :: rest | A.Json text :: rest -> loop (text :: acc) rest
    | A.Audio _ :: _ ->
        Stdlib.Error
          (A.Unsupported
             { provider = "anthropic"; feature = "audio content requires realtime" })
    | A.Image _ :: _ ->
        Stdlib.Error
          (A.Unsupported
             { provider = "anthropic"; feature = "image content cannot be encoded as text" })
    | A.Video _ :: _ ->
        Stdlib.Error
          (A.Unsupported { provider = "anthropic"; feature = "video content" })
  in
  loop [] contents

let content_is_text = function A.Text _ | A.Json _ -> true | _ -> false
let contents_are_text contents = List.for_all content_is_text contents

let cache_control_json =
  Json.object_ [ ("type", Some (Json.string "ephemeral")) ]

let text_block ?cache_control text =
  Json.object_
    [
      ("type", Some (Json.string "text"));
      ("text", Some (Json.string text));
      ("cache_control", cache_control);
    ]

let[@zero_alloc] equal_token url start stop token =
  let len = stop - start in
  len = String.length token
  &&
  let index = ref 0 in
  let equal = ref true in
  while !equal && !index < len do
    equal := Char.equal (String.unsafe_get url (start + !index)) token.[!index];
    incr index
  done;
  !equal

let[@zero_alloc] metadata_has_token url start stop token =
  let pos = ref start in
  let found = ref false in
  while (not !found) && !pos <= stop do
    let token_start = !pos in
    while !pos < stop && not (Char.equal (String.unsafe_get url !pos) ';') do
      incr pos
    done;
    found := equal_token url token_start !pos token;
    incr pos
  done;
  !found

let image_source media =
  match media.A.detail with
  | Some _ ->
      Stdlib.Error
        (A.Unsupported { provider = "anthropic"; feature = "image detail" })
  | None when Eta.String_helpers.starts_with media.url ~prefix:"data:" -> (
      match String.index_opt media.url ',' with
      | None ->
          Stdlib.Error
            (A.Unsupported
               { provider = "anthropic"; feature = "image data URL payload" })
      | Some comma ->
          let data =
            String.sub media.url (comma + 1)
              (String.length media.url - comma - 1)
          in
          let media_type_stop =
            match String.index_from_opt media.url 5 ';' with
            | Some semicolon when semicolon < comma -> semicolon
            | _ -> comma
          in
          let media_type =
            if media_type_stop = 5 then None
            else Some (String.sub media.url 5 (media_type_stop - 5))
          in
          if not (metadata_has_token media.url 5 comma "base64") then
            Stdlib.Error
              (A.Unsupported
                 { provider = "anthropic"; feature = "image data URL base64" })
          else
            match media_type with
            | None ->
                Stdlib.Error
                  (A.Unsupported
                     {
                       provider = "anthropic";
                       feature = "image data URL media_type";
                     })
            | Some media_type ->
                Stdlib.Ok
                  (Json.object_
                     [
                       ("type", Some (Json.string "base64"));
                       ("media_type", Some (Json.string media_type));
                       ("data", Some (Json.string data));
                     ]))
  | None ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "url"));
             ("url", Some (Json.string media.url));
           ])

let image_block media =
  image_source media
  |> Result.map (fun source ->
         Json.object_
           [
             ("type", Some (Json.string "image"));
             ("source", Some source);
           ])

let content_block = function
  | A.Text text -> Stdlib.Ok (text_block text)
  | A.Json raw -> parse_raw_json "content block" raw
  | A.Audio _ ->
      Stdlib.Error
        (A.Unsupported
           { provider = "anthropic"; feature = "audio content requires realtime" })
  | A.Image media -> image_block media
  | A.Video _ ->
      Stdlib.Error
        (A.Unsupported
           { provider = "anthropic"; feature = "video content" })

let content_blocks contents =
  result_map_all content_block contents

let tool_use_block (call : A.tool_call) =
  let* input =
    parse_raw_json
      ("tool call " ^ call.name ^ " arguments_json")
      call.arguments_json
  in
  Stdlib.Ok
    (Json.object_
       [
         ("type", Some (Json.string "tool_use"));
         ("id", Some (Json.string call.id));
         ("name", Some (Json.string call.name));
         ("input", Some input);
       ])

let tool_result_content contents =
  if contents_are_text contents then
    contents_text contents |> Result.map Json.string
  else content_blocks contents |> Result.map Json.array

let tool_result_block tool_call_id contents =
  tool_result_content contents
  |> Result.map (fun content ->
         Json.object_
           [
             ("type", Some (Json.string "tool_result"));
             ("tool_use_id", Some (Json.string tool_call_id));
             ("content", Some content);
           ])

let message_json (message : A.message) =
  match message with
  | A.System _ -> Stdlib.Ok None
  | A.User contents ->
      content_blocks contents
      |> Result.map (fun blocks ->
             Some
               (Json.object_
                  [
                    ("role", Some (Json.string "user"));
                    ("content", Some (Json.array blocks));
                  ]))
  | A.Assistant { content; tool_calls } ->
      let* blocks = content_blocks content in
      let* tool_blocks = result_map_all tool_use_block tool_calls in
      Stdlib.Ok
        (Some
           (Json.object_
              [
                ("role", Some (Json.string "assistant"));
                ("content", Some (Json.array (blocks @ tool_blocks)));
              ]))
  | A.Tool { tool_call_id; content } ->
      tool_result_block tool_call_id content
      |> Result.map (fun block ->
             Some
               (Json.object_
                  [
                    ("role", Some (Json.string "user"));
                    ("content", Some (Json.array [ block ]));
                  ]))

let system_texts prompt =
  prompt
  |> List.filter_map (function A.System text -> Some text | _ -> None)

let system_json ?prompt_cache prompt =
  match system_texts prompt with
  | [] -> None
  | systems ->
      let text = String.concat "\n" systems in
      (match prompt_cache with
      | Some { cache_system = true; _ } ->
          Some (Json.array [ text_block ~cache_control:cache_control_json text ])
      | _ -> Some (Json.string text))

let tool_json (tool : A.tool) =
  let* schema =
    parse_raw_json
      ("tool " ^ tool.name ^ " input_schema_json")
      tool.input_schema_json
  in
  Stdlib.Ok
    (Json.object_
       [
         ("name", Some (Json.string tool.name));
         ("description", Option.map Json.string tool.description);
         ("input_schema", Some schema);
       ])

let encode_messages ?prompt_cache (request : A.chat_request) =
  let max_tokens =
    match request.max_output_tokens with
    | Some value -> Stdlib.Ok value
    | None ->
        Stdlib.Error
          (A.Unsupported
             { provider = "anthropic"; feature = "max_output_tokens" })
  in
  let temperature =
    match request.temperature with
    | None -> Stdlib.Ok None
    | Some value -> (
        match Json.float value with
        | Some encoded -> Stdlib.Ok (Some encoded)
        | None ->
            Stdlib.Error
              (A.Unsupported
                 { provider = "anthropic"; feature = "non-finite temperature" }))
  in
  let* max_tokens = max_tokens in
  let* temperature = temperature in
  let* messages = result_all (List.map message_json request.prompt) in
  let* tools = result_map_all tool_json request.tools in
  Stdlib.Ok
    (Json.to_string
       (Json.object_
          [
            ("model", Some (Json.string request.model));
            ("system", system_json ?prompt_cache request.prompt);
            ("messages", Some (messages |> List.filter_map Fun.id |> Json.array));
            ("max_tokens", Some (Json.int max_tokens));
            ("stream", Some (Json.bool request.stream));
            ("temperature", temperature);
            ("tools", if tools = [] then None else Some (Json.array tools));
          ]))

let parse_json raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message ->
      Stdlib.Error
        (A.Decode_error { provider = "anthropic"; message; raw = Some raw })

let finish_reason = function
  | "end_turn" | "stop_sequence" -> A.Stop
  | "max_tokens" -> A.Length
  | "tool_use" -> A.Tool_calls
  | "refusal" | "safety" -> A.Content_filter
  | "error" -> A.Error
  | other -> A.Other other

let raw_int_field name json =
  Option.map (fun value -> (name, string_of_int value)) (Json.int_member name json)

let usage json =
  let input_tokens = Json.int_member "input_tokens" json in
  let output_tokens = Json.int_member "output_tokens" json in
  let total_tokens =
    match (input_tokens, output_tokens) with
    | Some input, Some output -> Some (input + output)
    | _ -> None
  in
  {
    A.input_tokens;
    output_tokens;
    total_tokens;
    raw =
      [
        raw_int_field "input_tokens" json;
        raw_int_field "output_tokens" json;
        raw_int_field "cache_creation_input_tokens" json;
        raw_int_field "cache_read_input_tokens" json;
      ]
      |> List.filter_map Fun.id;
  }

let tool_call_of_block block =
  match Json.string_member "type" block with
  | Some "tool_use" -> (
      match
        ( Json.string_member "id" block,
          Json.string_member "name" block,
          Json.member "input" block )
      with
      | Some id, Some name, Some input ->
          Some { A.id; name; arguments_json = Json.compact input }
      | _ -> None)
  | _ -> None

let text_of_block block =
  match Json.string_member "type" block with
  | Some "text" -> Json.string_member "text" block
  | _ -> None

let assistant_message content =
  let text =
    content |> List.filter_map text_of_block |> String.concat ""
  in
  let tool_calls = content |> List.filter_map tool_call_of_block in
  A.Assistant
    {
      content = (if String.equal text "" then [] else [ A.Text text ]);
      tool_calls;
    }

let decode_message raw =
  let* json = parse_json raw in
  let content = Json.array_member "content" json |> Option.value ~default:[] in
  let finish_reasons =
    match Json.string_member "stop_reason" json with
    | Some reason -> [ finish_reason reason ]
    | None -> []
  in
  Stdlib.Ok
    {
      A.id = Json.string_member "id" json;
      model = Json.string_member "model" json;
      message = assistant_message content;
      finish_reasons;
      usage = Option.map usage (Json.object_member "usage" json);
      raw = Some raw;
    }

let provider_error ?status ?code ?raw message =
  A.Provider_error
    { provider = "anthropic"; status; code; message; raw }

let decode_provider_error_json ?status raw json =
  match Json.object_member "error" json with
  | Some error_json ->
      let message =
        Json.string_member "message" error_json
        |> Option.value ~default:"provider returned an error"
      in
      let code = Json.string_member "type" error_json in
      provider_error ?status ?code ~raw message
  | None -> provider_error ?status ~raw "provider returned an error"

let decode_error ~status ~headers:_ raw =
  match Json.parse raw with
  | Stdlib.Ok json -> decode_provider_error_json ?status:(Some status) raw json
  | Stdlib.Error _ ->
      provider_error ?status:(Some status) ~raw "provider returned an error"

let stream_error raw json = decode_provider_error_json raw json

let stream_message_start raw json =
  match Json.object_member "message" json with
  | Some message ->
      [
        A.Stream_message_start
          {
            id = Json.string_member "id" message;
            model = Json.string_member "model" message;
            raw = Some raw;
          };
      ]
  | None -> []

let stream_content_block_start json =
  match Json.object_member "content_block" json with
  | Some block when Json.string_member "type" block = Some "tool_use" ->
      [
        A.Stream_tool_call_delta
          {
            index = Json.int_member "index" json;
            id = Json.string_member "id" block;
            name = Json.string_member "name" block;
            arguments_json_delta =
              (match Json.member "input" block with
              | Some (`Assoc []) | None -> ""
              | Some input -> Json.compact input);
          };
      ]
  | _ -> []

let stream_content_block_delta json =
  match Json.object_member "delta" json with
  | Some delta -> (
      match Json.string_member "type" delta with
      | Some "text_delta" -> (
          match Json.string_member "text" delta with
          | Some text -> [ A.Stream_content_delta text ]
          | None -> [])
      | Some "input_json_delta" ->
          [
            A.Stream_tool_call_delta
              {
                index = Json.int_member "index" json;
                id = None;
                name = None;
                arguments_json_delta =
                  Option.value ~default:""
                    (Json.string_member "partial_json" delta);
              };
          ]
      | _ -> [])
  | None -> []

let stream_message_delta json =
  match Json.object_member "delta" json with
  | Some delta -> (
      match Json.string_member "stop_reason" delta with
      | Some reason -> [ A.Stream_finish [ finish_reason reason ] ]
      | None -> [])
  | None -> []

let decode_stream_event (event : A.sse_event) =
  match Json.parse event.data with
  | Stdlib.Error message ->
      Stdlib.Error
        (A.Decode_error { provider = "anthropic"; message; raw = Some event.data })
  | Stdlib.Ok json -> (
      match event.event with
      | Some "message_start" -> Stdlib.Ok (stream_message_start event.data json)
      | Some "content_block_start" ->
          Stdlib.Ok (stream_content_block_start json)
      | Some "content_block_delta" ->
          Stdlib.Ok (stream_content_block_delta json)
      | Some "message_delta" -> Stdlib.Ok (stream_message_delta json)
      | Some "message_stop" -> Stdlib.Ok [ A.Stream_done ]
      | Some "error" -> Stdlib.Ok [ A.Stream_error (stream_error event.data json) ]
      | _ -> (
          match Json.string_member "type" json with
          | Some "error" ->
              Stdlib.Ok [ A.Stream_error (stream_error event.data json) ]
          | _ -> Stdlib.Ok []))

let auth_headers ~version ~beta_headers api_key =
  let beta =
    match beta_headers with
    | [] -> []
    | headers -> [ ("Anthropic-Beta", String.concat "," headers) ]
  in
  H.Core.Header.unsafe_of_list
    ([
       ("x-api-key", Eta_redacted.value api_key);
       ("anthropic-version", version);
       ("Content-Type", "application/json");
       ("Accept", "application/json");
     ]
    @ beta)

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = false;
    structured_outputs = false;
    text = true;
    image_input = true;
    audio_input = false;
    video_input = false;
    embeddings = false;
    image_generation = false;
    speech = false;
    transcription = false;
    rerank = false;
    video_generation = false;
  }

let unsupported_embeddings _request =
  Stdlib.Error
    (A.Unsupported { provider = "anthropic"; feature = "embeddings" })

let decode_embeddings _raw =
  Stdlib.Error
    (A.Unsupported { provider = "anthropic"; feature = "embeddings" })

let provider ?(base_url = "https://api.anthropic.com")
    ?(version = "2023-06-01") ?(beta_headers = []) () =
  {
    A.name = "anthropic";
    base_url;
    chat_path = "/v1/messages";
    embeddings_path = None;
    auth_headers = auth_headers ~version ~beta_headers;
    capabilities;
    encode_chat = encode_messages;
    decode_chat = decode_message;
    encode_embeddings = unsupported_embeddings;
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let with_prompt_cache_header prompt_cache headers =
  match prompt_cache with
  | None -> headers
  | Some { beta_header; _ } ->
      let existing = H.Core.Header.get_all "anthropic-beta" headers in
      let value = String.concat "," (existing @ [ beta_header ]) in
      headers |> H.Core.Header.remove "anthropic-beta"
      |> H.Core.Header.unsafe_add "Anthropic-Beta" value

let make_request ?prompt_cache provider api_key raw =
  let headers =
    provider.A.auth_headers api_key |> with_prompt_cache_header prompt_cache
  in
  A.provider_request { provider with A.auth_headers = (fun _ -> headers) } api_key
    raw

let messages_request ?prompt_cache ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let encoded =
    match prompt_cache with
    | None -> provider.A.encode_chat request
    | Some _ -> encode_messages ?prompt_cache request
  in
  encoded |> Result.map (make_request ?prompt_cache provider api_key)

let perform_message = A.perform_chat
let perform_stream = A.perform_stream

let messages ?prompt_cache ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match messages_request ?prompt_cache ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request
        (perform_message provider client http_request)

let stream_messages ?prompt_cache ?provider:custom_provider client ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let request = { request with A.stream = true } in
  match messages_request ?prompt_cache ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)

module Chat = struct
  include A.Provider.Chat

  let messages_request = messages_request
  let messages = messages
  let stream_messages = stream_messages
end

module Embeddings = A.Provider.Embeddings
