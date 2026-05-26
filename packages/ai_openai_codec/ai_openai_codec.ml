module A = Ai
module Json = A.Json

type structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let structured_output ~schema_value ?strict ~name ~schema_json () =
  let trimmed = String.trim name in
  if String.equal trimmed "" then
    Stdlib.Error
      (A.Invalid_tool { name; message = "structured output name is required" })
  else
    match schema_value "structured output schema_json" schema_json with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok schema -> Stdlib.Ok { name = trimmed; schema; strict }

let content_text = function
  | A.Text text -> text
  | A.Json raw -> raw
  | A.Audio _ -> invalid_arg "audio content cannot be encoded as text"

let contents_text contents = contents |> List.map content_text |> String.concat ""

let content_has_audio = function A.Audio _ -> true | A.Text _ | A.Json _ -> false

let message_has_audio = function
  | A.System _ -> false
  | A.User contents | A.Assistant { content = contents; _ }
  | A.Tool { content = contents; _ } ->
      List.exists content_has_audio contents

let reject_audio_prompt ~provider prompt =
  if List.exists message_has_audio prompt then
    Stdlib.Error
      (A.Unsupported
         { provider; feature = "audio content requires OpenAI Realtime" })
  else Stdlib.Ok ()

let decode_error_result ?raw ~provider message =
  Stdlib.Error (A.Decode_error { provider; message; raw })

let parse_json ~provider raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message -> decode_error_result ~provider ~raw message

let schema_value ~provider label raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message ->
      decode_error_result ~provider ~raw
        (Printf.sprintf "%s must be valid JSON: %s" label message)

let message_item role contents =
  Json.object_
    [
      ("role", Some (Json.string role));
      ("content", Some (Json.string (contents_text contents)));
    ]

let function_call_item (call : A.tool_call) =
  Json.object_
    [
      ("type", Some (Json.string "function_call"));
      ("call_id", Some (Json.string call.id));
      ("name", Some (Json.string call.name));
      ("arguments", Some (Json.string call.arguments_json));
    ]

let input_items = function
  | A.System text -> [ message_item "system" [ A.Text text ] ]
  | A.User contents -> [ message_item "user" contents ]
  | A.Assistant { content; tool_calls } ->
      let content_item =
        if String.equal (contents_text content) "" then []
        else [ message_item "assistant" content ]
      in
      content_item @ List.map function_call_item tool_calls
  | A.Tool { tool_call_id; content } ->
      [
        Json.object_
          [
            ("type", Some (Json.string "function_call_output"));
            ("call_id", Some (Json.string tool_call_id));
            ("output", Some (Json.string (contents_text content)));
          ];
      ]

let chat_message_json = function
  | A.System content ->
      Json.object_
        [
          ("role", Some (Json.string "system"));
          ("content", Some (Json.string content));
        ]
  | A.User contents ->
      Json.object_
        [
          ("role", Some (Json.string "user"));
          ("content", Some (Json.string (contents_text contents)));
        ]
  | A.Assistant { content; tool_calls } ->
      let tool_calls =
        match tool_calls with
        | [] -> None
        | calls ->
            calls
            |> List.map (fun (call : A.tool_call) ->
                   Json.object_
                     [
                       ("id", Some (Json.string call.id));
                       ("type", Some (Json.string "function"));
                       ( "function",
                         Some
                           (Json.object_
                              [
                                ("name", Some (Json.string call.name));
                                ("arguments", Some (Json.string call.arguments_json));
                              ]) );
                     ])
            |> Json.array |> Option.some
      in
      Json.object_
        [
          ("role", Some (Json.string "assistant"));
          ("content", Some (Json.string (contents_text content)));
          ("tool_calls", tool_calls);
        ]
  | A.Tool { tool_call_id; content } ->
      Json.object_
        [
          ("role", Some (Json.string "tool"));
          ("tool_call_id", Some (Json.string tool_call_id));
          ("content", Some (Json.string (contents_text content)));
        ]

type tool_shape =
  | Chat_tool
  | Responses_tool

let tool_json ~schema_value ~shape (tool : A.tool) =
  match
    schema_value
      ("tool " ^ tool.name ^ " input_schema_json")
      tool.input_schema_json
  with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok schema ->
      let function_fields =
        [
          ("name", Some (Json.string tool.name));
          ("description", Option.map Json.string tool.description);
          ("parameters", Some schema);
          ("strict", Option.map Json.bool tool.strict);
        ]
      in
      let json =
        match shape with
        | Chat_tool ->
            Json.object_
              [
                ("type", Some (Json.string "function"));
                ("function", Some (Json.object_ function_fields));
              ]
        | Responses_tool ->
            Json.object_
              [
                ("type", Some (Json.string "function"));
                ("name", Some (Json.string tool.name));
                ("description", Option.map Json.string tool.description);
                ("parameters", Some schema);
                ("strict", Option.map Json.bool tool.strict);
              ]
      in
      Stdlib.Ok json

type structured_output_shape =
  | Chat_response_format
  | Responses_format

let structured_output_json ~shape output =
  match shape with
  | Chat_response_format ->
      Json.object_
        [
          ("type", Some (Json.string "json_schema"));
          ( "json_schema",
            Some
              (Json.object_
                 [
                   ("name", Some (Json.string output.name));
                   ("schema", Some output.schema);
                   ("strict", Option.map Json.bool output.strict);
                 ]) );
        ]
  | Responses_format ->
      Json.object_
        [
          ("type", Some (Json.string "json_schema"));
          ("name", Some (Json.string output.name));
          ("schema", Some output.schema);
          ("strict", Option.map Json.bool output.strict);
        ]

let result_all values =
  let rec loop acc = function
    | [] -> Stdlib.Ok (List.rev acc)
    | Stdlib.Ok value :: rest -> loop (value :: acc) rest
    | Stdlib.Error _ as error :: _ -> error
  in
  loop [] values

let temperature_json ~provider = function
  | None -> Stdlib.Ok None
  | Some value -> (
      match Json.float value with
      | Some encoded -> Stdlib.Ok (Some encoded)
      | None ->
          Stdlib.Error
            (A.Unsupported { provider; feature = "non-finite temperature" }))

let encode_chat_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  match reject_audio_prompt ~provider request.prompt with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok () -> (
      match temperature_json ~provider request.temperature with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok temperature -> (
      match
        result_all
          (List.map
             (tool_json ~schema_value ~shape:Chat_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools ->
          let response_format =
            structured_output
            |> Option.map
                 (structured_output_json ~shape:Chat_response_format)
          in
          Stdlib.Ok
            (Json.object_
               [
                 ("model", Some (Json.string request.model));
                 ( "messages",
                   Some (request.prompt |> List.map chat_message_json |> Json.array) );
                 ("stream", Some (Json.bool request.stream));
                 ("temperature", temperature);
                 ("max_tokens", Option.map Json.int request.max_output_tokens);
                 ("tools", if tools = [] then None else Some (Json.array tools));
                 ("response_format", response_format);
               ])))

let encode_chat ~provider ~schema_value ?structured_output request =
  match encode_chat_json ~provider ~schema_value ?structured_output request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let encode_responses_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  match reject_audio_prompt ~provider request.prompt with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok () -> (
      match temperature_json ~provider request.temperature with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok temperature -> (
      match
        result_all
          (List.map
             (tool_json ~schema_value ~shape:Responses_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools ->
          let text_format =
            structured_output
            |> Option.map (fun output ->
                   let format =
                     structured_output_json ~shape:Responses_format output
                   in
                   Json.object_ [ ("format", Some format) ])
          in
          Stdlib.Ok
            (Json.object_
               [
                 ("model", Some (Json.string request.model));
                 ( "input",
                   Some
                     (request.prompt |> List.concat_map input_items |> Json.array) );
                 ("stream", Some (Json.bool request.stream));
                 ("temperature", temperature);
                 ( "max_output_tokens",
                   Option.map Json.int request.max_output_tokens );
                 ("tools", if tools = [] then None else Some (Json.array tools));
                 ("text", text_format);
               ])))

let encode_responses ~provider ~schema_value ?structured_output request =
  match
    encode_responses_json ~provider ~schema_value ?structured_output request
  with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let finish_reason = function
  | "stop" -> A.Stop
  | "length" -> A.Length
  | "tool_calls" -> A.Tool_calls
  | "content_filter" -> A.Content_filter
  | "error" -> A.Error
  | other -> A.Other other

let int_member first second json =
  match Json.int_member first json with
  | Some _ as value -> value
  | None -> Json.int_member second json

let usage ?(raw_prompt_names = false) json =
  let input_tokens = int_member "prompt_tokens" "input_tokens" json in
  let output_tokens = int_member "completion_tokens" "output_tokens" json in
  let total_tokens = Json.int_member "total_tokens" json in
  let input_name, output_name =
    if raw_prompt_names then ("prompt_tokens", "completion_tokens")
    else ("input_tokens", "output_tokens")
  in
  {
    A.input_tokens;
    output_tokens;
    total_tokens;
    raw =
      [
        (input_name, Option.value ~default:"" (Option.map string_of_int input_tokens));
        ( output_name,
          Option.value ~default:"" (Option.map string_of_int output_tokens) );
        ("total_tokens", Option.value ~default:"" (Option.map string_of_int total_tokens));
      ];
  }

let raw_json = function
  | `String value -> value
  | json -> Json.compact json

let chat_tool_call json =
  let function_json = Json.object_member "function" json in
  let name =
    match function_json with
    | Some fn -> Json.string_member "name" fn
    | None -> Json.string_member "name" json
  in
  let arguments =
    match function_json with
    | Some fn -> Json.member "arguments" fn
    | None -> Json.member "arguments" json
  in
  match (Json.string_member "id" json, name, arguments) with
  | id, Some name, Some arguments ->
      Some
        {
          A.id = Option.value ~default:"" id;
          name;
          arguments_json = raw_json arguments;
        }
  | _ -> None

let assistant_message message_json =
  let content =
    match Json.string_member "content" message_json with
    | Some "" | None -> []
    | Some text -> [ A.Text text ]
  in
  let tool_calls =
    Json.array_member "tool_calls" message_json
    |> Option.value ~default:[] |> List.filter_map chat_tool_call
  in
  A.Assistant { content; tool_calls }

let decode_chat ?(usage_raw_prompt_names = false) ~provider raw =
  match parse_json ~provider raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "choices" json with
      | Some (choice :: _ as choices) -> (
          match Json.object_member "message" choice with
          | Some message_json ->
              let finish_reasons =
                choices
                |> List.filter_map (Json.string_member "finish_reason")
                |> List.map finish_reason
              in
              Stdlib.Ok
                {
                  A.id = Json.string_member "id" json;
                  model = Json.string_member "model" json;
                  message = assistant_message message_json;
                  finish_reasons;
                  usage =
                    Option.map
                      (usage ~raw_prompt_names:usage_raw_prompt_names)
                      (Json.object_member "usage" json);
                  raw = Some raw;
                }
          | None ->
              decode_error_result ~provider ~raw
                "chat completion choice missing message")
      | _ ->
          decode_error_result ~provider ~raw "chat completion missing choices")

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

let responses_tool_call item =
  match Json.string_member "type" item with
  | Some "function_call" ->
      let id =
        match Json.string_member "call_id" item with
        | Some _ as value -> value
        | None -> Json.string_member "id" item
      in
      let arguments =
        match Json.member "arguments" item with
        | Some (`String arguments) -> Some arguments
        | Some json -> Some (Json.compact json)
        | None -> None
      in
      (match (Json.string_member "name" item, arguments) with
      | Some name, Some arguments_json ->
          Some { A.id = Option.value ~default:"" id; name; arguments_json }
      | _ -> None)
  | _ -> None

let status_finish json =
  match Json.string_member "status" json with
  | Some "completed" -> [ A.Stop ]
  | Some "incomplete" -> [ A.Length ]
  | Some "failed" -> [ A.Error ]
  | Some status -> [ A.Other status ]
  | None -> []

let decode_responses ~provider raw =
  match parse_json ~provider raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      let output = Json.array_member "output" json |> Option.value ~default:[] in
      let text = output |> List.concat_map output_text |> String.concat "" in
      let tool_calls = output |> List.filter_map responses_tool_call in
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

let error_object ?(nested_response_error = false) json =
  match Json.object_member "error" json with
  | Some _ as value -> value
  | None ->
      if nested_response_error then
        Option.bind
          (Json.object_member "response" json)
          (Json.object_member "error")
      else None

let provider_error_json ?status ?raw ?(nested_response_error = false) ~provider
    json =
  let error = error_object ~nested_response_error json in
  let message =
    Option.bind error (Json.string_member "message")
    |> Option.value ~default:"provider returned an error"
  in
  let code =
    match Option.bind error (Json.scalar_string_member "code") with
    | Some _ as value -> value
    | None -> Option.bind error (Json.string_member "type")
  in
  A.Provider_error { provider; status; code; message; raw }

let provider_error ?status ?(nested_response_error = false) ~provider raw =
  match Json.parse raw with
  | Stdlib.Ok json ->
      provider_error_json ?status ~raw ~nested_response_error ~provider json
  | Stdlib.Error _ ->
      A.Provider_error
        {
          provider;
          status;
          code = None;
          message = "provider returned an error";
          raw = Some raw;
        }

let decode_error ?(nested_response_error = false) ~provider ~status ~headers:_
    raw =
  provider_error ~status ~nested_response_error ~provider raw

let stream_tool_delta json =
  let index = Json.int_member "index" json in
  let id = Json.string_member "id" json in
  let function_json = Json.object_member "function" json in
  let name = Option.bind function_json (Json.string_member "name") in
  let arguments_json_delta =
    match Option.bind function_json (Json.member "arguments") with
    | Some (`String value) -> value
    | Some value -> Json.compact value
    | None -> ""
  in
  A.Stream_tool_call_delta { index; id; name; arguments_json_delta }

let chat_stream_events ~finish_reason raw json =
  let choices = Json.array_member "choices" json |> Option.value ~default:[] in
  let starts =
    choices
    |> List.filter_map (fun choice ->
           match Json.object_member "delta" choice with
           | Some delta when Json.string_member "role" delta = Some "assistant" ->
               Some
                 (A.Stream_message_start
                    {
                      id = Json.string_member "id" json;
                      model = Json.string_member "model" json;
                      raw = Some raw;
                    })
           | _ -> None)
  in
  let deltas =
    choices
    |> List.concat_map (fun choice ->
           match Json.object_member "delta" choice with
           | None -> []
           | Some delta ->
               let content =
                 match Json.string_member "content" delta with
                 | Some text -> [ A.Stream_content_delta text ]
                 | None -> []
               in
               let tool_calls =
                 Json.array_member "tool_calls" delta
                 |> Option.value ~default:[]
                 |> List.map stream_tool_delta
               in
               content @ tool_calls)
  in
  let finishes =
    choices
    |> List.filter_map (Json.string_member "finish_reason")
    |> List.map finish_reason
  in
  starts @ deltas
  @ if finishes = [] then [] else [ A.Stream_finish finishes ]

let responses_stream_tool_delta json =
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

let responses_stream_events ?(nested_response_error = false) ~provider raw
    event_name json =
  match event_name with
  | Some "response.output_text.delta" -> (
      match Json.string_member "delta" json with
      | Some text -> [ A.Stream_content_delta text ]
      | None -> [])
  | Some "response.function_call_arguments.delta" ->
      [ responses_stream_tool_delta json ]
  | Some "response.completed" -> [ A.Stream_finish [ A.Stop ]; A.Stream_done ]
  | Some "response.incomplete" -> [ A.Stream_finish [ A.Length ] ]
  | Some "response.failed" ->
      [
        A.Stream_error
          (provider_error_json ~raw ~nested_response_error ~provider json);
      ]
  | _ -> []

let decode_stream_event ?(nested_response_error = false) ~provider event =
  let data = String.trim event.A.data in
  if String.equal data "[DONE]" then Stdlib.Ok [ A.Stream_done ]
  else
    match parse_json ~provider data with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok json ->
        if Option.is_some (error_object ~nested_response_error json) then
          Stdlib.Ok
            [
              A.Stream_error
                (provider_error_json ~raw:data ~nested_response_error ~provider
                   json);
            ]
        else
          let response_events =
            responses_stream_events ~nested_response_error ~provider data
              (response_event_name event json) json
          in
          if response_events = [] then
            Stdlib.Ok (chat_stream_events ~finish_reason data json)
          else Stdlib.Ok response_events
