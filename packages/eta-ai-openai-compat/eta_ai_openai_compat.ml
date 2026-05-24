module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

type auth = {
  header : string;
  prefix : string option;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema_json : A.raw_json;
  strict : bool option;
}

let decode_error_result ?raw message =
  Stdlib.Error
    (A.Decode_error { provider = "openai-compatible"; message; raw })

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

let bearer_auth ?(header = "Authorization") () =
  { header; prefix = Some "Bearer " }

let raw_header_auth ~header () = { header; prefix = None }

let auth_value auth api_key =
  Option.value ~default:"" auth.prefix ^ Eta_redacted.value api_key

let message_json = function
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
                                ("arguments", Some (Json.string call.arguments_json));
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

let encode_chat ?structured_output (request : A.chat_request) =
  let temperature =
    match request.temperature with
    | None -> Stdlib.Ok None
    | Some value -> (
        match Json.float value with
        | Some encoded -> Stdlib.Ok (Some encoded)
        | None ->
            Stdlib.Error
              (A.Unsupported
                 {
                   provider = "openai-compatible";
                   feature = "non-finite temperature";
                 }))
  in
  match temperature with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok temperature -> (
      match
        Codec.result_all
          (List.map
             (Codec.tool_json ~schema_value:require_json
                ~shape:Codec.Chat_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools -> (
          match
            Option.fold ~none:(Stdlib.Ok None)
              ~some:(fun output ->
                Codec.structured_output_json ~schema_value:require_json
                  ~shape:Codec.Chat_response_format output
                |> Result.map (fun value -> Some value))
              structured_output
          with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok response_format ->
              Stdlib.Ok
                (Json.to_string
                   (Json.object_
                      [
                        ("model", Some (Json.string request.model));
                        ( "messages",
                          Some
                            (request.prompt |> List.map message_json
                           |> Json.array) );
                        ("stream", Some (Json.bool request.stream));
                        ("temperature", temperature);
                        ( "max_tokens",
                          Option.map Json.int request.max_output_tokens );
                        ( "tools",
                          if tools = [] then None else Some (Json.array tools) );
                        ("response_format", response_format);
                      ]))))

let finish_reason = function
  | "stop" -> A.Stop
  | "length" -> A.Length
  | "tool_calls" -> A.Tool_calls
  | "content_filter" -> A.Content_filter
  | "error" -> A.Error
  | other -> A.Other other

let raw_json = function
  | `String value -> value
  | json -> Json.compact json

let usage json =
  let input_tokens = Json.int_member "prompt_tokens" json in
  let output_tokens = Json.int_member "completion_tokens" json in
  let total_tokens = Json.int_member "total_tokens" json in
  {
    A.input_tokens;
    output_tokens;
    total_tokens;
    raw =
      [
        ("prompt_tokens", Option.value ~default:"" (Option.map string_of_int input_tokens));
        ( "completion_tokens",
          Option.value ~default:"" (Option.map string_of_int output_tokens) );
        ("total_tokens", Option.value ~default:"" (Option.map string_of_int total_tokens));
      ];
  }

let tool_call json =
  let function_json = Json.object_member "function" json in
  match
    ( Json.string_member "id" json,
      Option.bind function_json (Json.string_member "name"),
      Option.bind function_json (Json.member "arguments") )
  with
  | Some id, Some name, Some arguments ->
      Some { A.id; name; arguments_json = raw_json arguments }
  | _ -> None

let decode_chat raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      let choices = Json.array_member "choices" json |> Option.value ~default:[] in
      let message =
        choices
        |> List.find_map (fun choice -> Json.object_member "message" choice)
      in
      let text =
        match Option.bind message (Json.string_member "content") with
        | Some value -> [ A.Text value ]
        | None -> []
      in
      let tool_calls =
        match message with
        | Some message ->
            Json.array_member "tool_calls" message
            |> Option.value ~default:[] |> List.filter_map tool_call
        | None -> []
      in
      let finish_reasons =
        choices
        |> List.filter_map (Json.string_member "finish_reason")
        |> List.map finish_reason
      in
      Stdlib.Ok
        {
          A.id = Json.string_member "id" json;
          model = Json.string_member "model" json;
          message = A.Assistant { content = text; tool_calls };
          finish_reasons;
          usage = Option.map usage (Json.object_member "usage" json);
          raw = Some raw;
        }

let provider_error ?status ?(provider = "openai-compatible") raw =
  let error =
    match parse_json raw with
    | Stdlib.Ok json -> Json.object_member "error" json
    | Stdlib.Error _ -> None
  in
  let message =
    Option.bind error (Json.string_member "message")
    |> Option.value ~default:"provider returned an error"
  in
  let code = Option.bind error (Json.scalar_string_member "code") in
  A.Provider_error { provider; status; code; message; raw = Some raw }

let decode_error ~status ~headers:_ raw =
  provider_error ?status:(Some status) raw

let decode_stream_event (event : A.sse_event) =
  let data = String.trim event.data in
  if String.equal data "[DONE]" then Stdlib.Ok [ A.Stream_done ]
  else
    match parse_json data with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok json ->
        if Option.is_some (Json.object_member "error" json) then
          Stdlib.Ok [ A.Stream_error (provider_error data) ]
        else
          let choices =
            Json.array_member "choices" json |> Option.value ~default:[]
          in
          let content =
            choices
            |> List.filter_map (fun choice ->
                   Option.bind (Json.object_member "delta" choice)
                     (Json.string_member "content"))
            |> List.filter (fun value -> not (String.equal value ""))
            |> List.map (fun value -> A.Stream_content_delta value)
          in
          let finish =
            choices
            |> List.filter_map (Json.string_member "finish_reason")
            |> List.map finish_reason
          in
          let finish =
            match finish with [] -> [] | reasons -> [ A.Stream_finish reasons ]
          in
          Stdlib.Ok (content @ finish)

let provider ?(name = "openai-compatible")
    ?(chat_path = "/v1/chat/completions") ?(auth = bearer_auth ())
    ?(extra_headers = []) ~base_url () =
  let auth_headers api_key =
    H.Core.Header.unsafe_of_list
      ([
         (auth.header, auth_value auth api_key);
         ("Content-Type", "application/json");
         ("Accept", "application/json");
       ]
      @ extra_headers)
  in
  {
    A.name;
    base_url;
    chat_path;
    auth_headers;
    capabilities =
      {
        A.streaming = true;
        tools = true;
        tool_choice = true;
        structured_outputs = true;
      };
    encode_chat = encode_chat;
    decode_chat;
    decode_stream_event;
    decode_error =
      (fun ~status ~headers raw ->
        match decode_error ~status ~headers raw with
        | A.Provider_error error -> A.Provider_error { error with provider = name }
        | error -> error);
  }

let make_request = A.provider_request

let chat_completions_request ?structured_output ~provider ~api_key request =
  match encode_chat ?structured_output request with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let perform_chat = A.perform_chat
let perform_stream = A.perform_stream

let chat_completions ?structured_output ~provider client ~api_key request =
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let stream_chat_completions ?structured_output ~provider client ~api_key request =
  let request = { request with A.stream = true } in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)
