module A = Eta_ai
module Common = Eta_ai_openai_common
module Codec = Eta_ai_openai_codec
module Json = Common.Json

let message_json (message : A.message) =
  match message with
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
          ("content", Some (Json.string (Codec.contents_text contents)));
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
                                ( "arguments",
                                  Some (Json.string call.arguments_json) );
                              ]) );
                     ])
            |> Json.array |> Option.some
      in
      Json.object_
        [
          ("role", Some (Json.string "assistant"));
          ("content", Some (Json.string (Codec.contents_text content)));
          ("tool_calls", tool_calls);
        ]
  | A.Tool { tool_call_id; content } ->
      Json.object_
        [
          ("role", Some (Json.string "tool"));
          ("tool_call_id", Some (Json.string tool_call_id));
          ("content", Some (Json.string (Codec.contents_text content)));
        ]

let encode ?structured_output (request : A.chat_request) =
  let temperature =
    match request.temperature with
    | None -> Stdlib.Ok None
    | Some value -> (
        match Json.float value with
        | Some encoded -> Stdlib.Ok (Some encoded)
        | None ->
            Stdlib.Error
              (A.Unsupported
                 { provider = "openai"; feature = "non-finite temperature" }))
  in
  match temperature with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok temperature -> (
      match
        Codec.result_all
          (List.map
             (Codec.tool_json ~schema_value:Common.schema_value
                ~shape:Codec.Chat_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools ->
          let response_format =
            structured_output
            |> Option.map
                 (Codec.structured_output_json
                    ~shape:Codec.Chat_response_format)
          in
          Stdlib.Ok
            (Json.to_string
               (Json.object_
                  [
                    ("model", Some (Json.string request.model));
                    ( "messages",
                      Some
                        (request.prompt |> List.map message_json |> Json.array) );
                    ("stream", Some (Json.bool request.stream));
                    ("temperature", temperature);
                    ("max_tokens", Option.map Json.int request.max_output_tokens);
                    ("tools", if tools = [] then None else Some (Json.array tools));
                    ("response_format", response_format);
                  ])))

let tool_call_of_json json =
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
  | id, Some name, Some (`String arguments) ->
      Some { A.id = Option.value ~default:"" id; name; arguments_json = arguments }
  | id, Some name, Some arguments ->
      Some
        {
          A.id = Option.value ~default:"" id;
          name;
          arguments_json = Json.compact arguments;
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
    |> Option.value ~default:[]
    |> List.filter_map tool_call_of_json
  in
  A.Assistant { content; tool_calls }

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "choices" json with
      | Some (choice :: _) -> (
          match Json.object_member "message" choice with
          | Some message_json ->
              let finish_reasons =
                Json.array_member "choices" json |> Option.value ~default:[]
                |> List.filter_map (Json.string_member "finish_reason")
                |> List.map Common.finish_reason
              in
              Stdlib.Ok
                {
                  A.id = Json.string_member "id" json;
                  model = Json.string_member "model" json;
                  message = assistant_message message_json;
                  finish_reasons;
                  usage = Option.map Common.usage (Json.object_member "usage" json);
                  raw = Some raw;
                }
          | None ->
              Stdlib.Error
                (A.Decode_error
                   {
                     provider = "openai";
                     message = "chat completion choice missing message";
                     raw = Some raw;
                   }))
      | _ ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openai";
                 message = "chat completion missing choices";
                 raw = Some raw;
               }))
