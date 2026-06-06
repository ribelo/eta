module A = Eta_ai
module O = Eta_ai_anthropic
module E = Eta.Effect
module H = Eta_http

let read_fixture name =
  let path = Filename.concat "fixtures" name in
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let expect_ok label = function
  | Stdlib.Ok value -> value
  | Stdlib.Error _ -> Alcotest.fail ("expected Ok: " ^ label)

let contains ~needle value =
  let needle_len = String.length needle in
  let value_len = String.length value in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > value_len then false
    else if String.sub value index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let require_contains label ~needle value =
  Alcotest.(check bool) label true (contains ~needle value)

let weather_schema =
  "{\"type\":\"object\",\"required\":[\"location\"],\"properties\":{\"location\":{\"type\":\"string\"}},\"additionalProperties\":false}"

let weather_tool () =
  A.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok "weather tool"

let chat_request ?(stream = false) ?(max_output_tokens = Some 64) () :
    A.chat_request =
  {
    model = "claude-3-5-sonnet-latest";
    prompt = [ A.System "stay brief"; A.User [ A.Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens;
    stream;
  }

let assistant_text = function
  | A.Assistant { content; _ } ->
      content
      |> List.filter_map (function
           | A.Text text -> Some text
           | A.Json _ | A.Audio _ | A.Image _ | A.Video _ -> None)
      |> String.concat ""
  | _ -> Alcotest.fail "expected assistant message"

let assistant_tool_calls = function
  | A.Assistant { tool_calls; _ } -> tool_calls
  | _ -> Alcotest.fail "expected assistant message"

let chunk_string value =
  let sizes = [| 7; 3; 19; 2; 11 |] in
  let rec loop index size_index acc =
    if index >= String.length value then List.rev acc
    else
      let size = sizes.(size_index mod Array.length sizes) in
      let len = min size (String.length value - index) in
      loop (index + len) (size_index + 1)
        (Bytes.of_string (String.sub value index len) :: acc)
  in
  loop 0 0 []

let body_of_fixture name =
  H.Body.Stream.of_bytes (chunk_string (read_fixture name))

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f rt tracer

let run_ok rt label eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s failed: %a" label
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<ai-error>"))
        cause

let zero_stats =
  {
    H.Client.protocol = H.Client.H1;
    active = 0;
    idle = 0;
    capacity = 0;
    opened = 0;
    released = 0;
  }

let response_of_fixture ?(status = 200) ?(headers = []) name =
  H.Response.make ~status ~headers ~body:(body_of_fixture name) ()

let test_client ?(with_http_span = false) response captured =
  let request http_request =
    captured := Some http_request;
    let eff = E.pure response in
    if with_http_span then
      E.named_kind ~kind:Eta.Capabilities.Client "HTTP POST" eff
    else eff
  in
  H.Client.make_custom ~protocol:H.Client.H1 ~request
    ~stats:(fun () -> E.pure zero_stats)
    ~shutdown:(fun () -> E.unit)

let request_body_string (request : H.Request.t) =
  match request.body with
  | H.Request.Fixed chunks ->
      chunks |> List.map Bytes.to_string |> String.concat ""
  | H.Request.Empty -> ""
  | H.Request.Stream _ | H.Request.Rewindable_stream _ ->
      Alcotest.fail "expected fixed request body"

let test_provider_value () =
  let provider =
    O.provider ~base_url:"https://api.anthropic.test"
      ~version:"2023-06-01" ~beta_headers:[ "messages-2024-01-01" ] ()
  in
  Alcotest.(check string) "name" "anthropic" provider.name;
  Alcotest.(check string) "path" "/v1/messages" provider.chat_path;
  Alcotest.(check bool) "streaming" true provider.capabilities.streaming;
  Alcotest.(check bool) "tools" true provider.capabilities.tools;
  let headers = provider.auth_headers (A.api_key "sk-ant-test") in
  Alcotest.(check (option string))
    "x-api-key" (Some "sk-ant-test")
    (H.Core.Header.get "x-api-key" headers);
  Alcotest.(check (option string))
    "version" (Some "2023-06-01")
    (H.Core.Header.get "anthropic-version" headers);
  Alcotest.(check (option string))
    "beta" (Some "messages-2024-01-01")
    (H.Core.Header.get "anthropic-beta" headers)

let test_encode_messages_tools_and_cache () =
  let prompt_cache = O.prompt_cache ~cache_system:true () in
  let raw =
    O.encode_messages ~prompt_cache (chat_request ()) |> expect_ok "messages"
  in
  require_contains "model" ~needle:"\"model\":\"claude-3-5-sonnet-latest\""
    raw;
  require_contains "top-level system" ~needle:"\"system\":[" raw;
  require_contains "cache control"
    ~needle:"\"cache_control\":{\"type\":\"ephemeral\"}" raw;
  require_contains "messages" ~needle:"\"messages\":[" raw;
  require_contains "max tokens" ~needle:"\"max_tokens\":64" raw;
  require_contains "tool schema"
    ~needle:"\"input_schema\":{\"type\":\"object\"" raw;
  let tool_result =
    {
      (chat_request ()) with
      prompt =
        [
          A.User [ A.Text "weather in Warsaw" ];
          A.Tool
            {
              tool_call_id = "toolu_weather";
              content = [ A.Text "{\"temperature\":21}" ];
            };
        ];
    }
  in
  let raw = O.encode_messages tool_result |> expect_ok "tool result" in
  require_contains "tool result block" ~needle:"\"type\":\"tool_result\""
    raw

let test_encode_requires_max_tokens () =
  match O.encode_messages (chat_request ~max_output_tokens:None ()) with
  | Stdlib.Error
      (A.Unsupported
        { provider = "anthropic"; feature = "max_output_tokens" }) ->
      ()
  | _ -> Alcotest.fail "expected max_output_tokens rejection"

(* P1: Anthropic provider crashes on image inputs.
   Claude 3+ supports vision. The provider should encode images,
   not crash or return Unsupported. *)

let test_encode_user_image_does_not_reject () =
  (* Claude 3+ supports image inputs in user messages.
     The provider should encode them as image content blocks, not
     return Unsupported. This test will be red if the provider
     rejects images. *)
  let request : A.chat_request =
    {
      model = "claude-3-5-sonnet-latest";
      prompt =
        [
          A.User
            [
              A.Text "What is in this image?";
              A.Image
                {
                  url = "data:image/png;charset=utf-8;base64,iVBORw0KGgo=";
                  detail = None;
                };
            ];
        ];
      tools = [];
      temperature = None;
      max_output_tokens = Some 100;
      stream = false;
    }
  in
  match O.encode_messages request with
  | Stdlib.Ok raw ->
      (* Should contain the image content block *)
      require_contains "image block" ~needle:"image" raw;
      require_contains "media type" ~needle:"\"media_type\":\"image/png\"" raw
  | Stdlib.Error (A.Unsupported { feature; _ }) ->
      Alcotest.failf
        "user image should be supported by Claude 3+ but got Unsupported: %s"
        feature
  | Stdlib.Error err ->
      Alcotest.failf "unexpected error encoding image: %s"
        (match err with
         | A.Unsupported { feature; _ } -> "Unsupported: " ^ feature
         | _ -> "other error")

let test_encode_tool_result_with_image_does_not_crash () =
  (* When a tool result contains an image, contents_text throws
     Invalid_argument which crashes the runtime. This should either:
     - Encode the image properly (Anthropic supports image tool results)
     - Return a typed error (Error _)
     It must NOT throw an uncatchable exception. *)
  let request : A.chat_request =
    {
      model = "claude-3-5-sonnet-latest";
      prompt =
        [
          A.User [ A.Text "take screenshot" ];
          A.Tool
            {
              tool_call_id = "toolu_screenshot";
              content =
                [
                  A.Text "Screenshot taken:";
                  A.Image { url = "data:image/png;base64,iVBORw0KGgo="; detail = None };
                ];
            };
        ];
      tools = [];
      temperature = None;
      max_output_tokens = Some 100;
      stream = false;
    }
  in
  (* This must not raise Invalid_argument. A typed Error result is acceptable;
     an uncatchable exception is not. *)
  let crashed =
    try
      ignore (O.encode_messages request);
      false
    with Invalid_argument _ -> true
  in
  Alcotest.(check bool)
    "encode_messages should NOT throw Invalid_argument on image in tool result \
     (should return typed Error instead)"
    false crashed

let test_decode_message_fixture () =
  let response =
    O.decode_message (read_fixture "message.json") |> expect_ok "message"
  in
  Alcotest.(check (option string)) "id" (Some "msg_fixture") response.id;
  Alcotest.(check string) "text" "Sunny and 21C"
    (assistant_text response.message);
  Alcotest.(check bool) "stop" true
    (List.exists (function A.Stop -> true | _ -> false) response.finish_reasons);
  Alcotest.(check (option int))
    "input tokens" (Some 13)
    (Option.bind response.usage (fun usage -> usage.A.input_tokens));
  Alcotest.(check bool)
    "cache token preserved" true
    (Option.value ~default:[]
       (Option.map (fun (usage : A.usage) -> usage.raw) response.usage)
    |> List.exists (fun (key, value) ->
           String.equal key "cache_read_input_tokens"
           && String.equal value "6"))

let test_decode_tool_fixture () =
  let response =
    O.decode_message (read_fixture "tool_message.json")
    |> expect_ok "tool message"
  in
  match assistant_tool_calls response.message with
  | [ call ] ->
      Alcotest.(check string) "id" "toolu_weather" call.id;
      Alcotest.(check string) "name" "weather" call.name;
      Alcotest.(check string)
        "arguments" "{\"location\":\"Warsaw\"}" call.arguments_json;
      Alcotest.(check bool) "tool finish" true
        (List.exists
           (function A.Tool_calls -> true | _ -> false)
           response.finish_reasons)
  | _ -> Alcotest.fail "expected one tool call"

let stream_text events =
  events
  |> List.filter_map (function
       | A.Stream_content_delta text -> Some text
       | _ -> None)
  |> String.concat ""

let stream_tool_args events =
  events
  |> List.filter_map (function
       | A.Stream_tool_call_delta { arguments_json_delta; _ } ->
           Some arguments_json_delta
       | _ -> None)
  |> String.concat ""

let stream_tool_names events =
  events
  |> List.filter_map (function
       | A.Stream_tool_call_delta { name = Some name; _ } -> Some name
       | _ -> None)

let has_done events =
  List.exists (function A.Stream_done -> true | _ -> false) events

let has_tool_finish events =
  List.exists
    (function
      | A.Stream_finish reasons ->
          List.exists (function A.Tool_calls -> true | _ -> false) reasons
      | _ -> false)
    events

let test_stream_fixture () =
  with_runtime @@ fun rt ->
  let stream =
    A.stream_of_body (O.provider ()) (body_of_fixture "stream_tool.sse")
  in
  let events = run_ok rt "read stream fixture" (A.read_stream_events stream) in
  Alcotest.(check string) "text" "Hello" (stream_text events);
  Alcotest.(check string)
    "tool args" "{\"location\":\"Warsaw\"}" (stream_tool_args events);
  Alcotest.(check (list string)) "tool name" [ "weather" ]
    (stream_tool_names events);
  Alcotest.(check bool) "tool finish" true (has_tool_finish events);
  Alcotest.(check bool) "done" true (has_done events)

let test_stream_error_fixture () =
  match
    O.decode_stream_event
      { A.event = Some "error"; data = read_fixture "error.json" }
  with
  | Stdlib.Ok
      [
        A.Stream_error
          (A.Provider_error
            {
              provider = "anthropic";
              code = Some "overloaded_error";
              message = "Overloaded";
              _;
            });
      ] ->
      ()
  | _ -> Alcotest.fail "expected stream provider error"

let test_stream_error_accepts_padded_json () =
  match
    O.decode_stream_event
      { A.event = Some "error"; data = " \n" ^ read_fixture "error.json" ^ "\t" }
  with
  | Stdlib.Ok [ A.Stream_error (A.Provider_error { message = "Overloaded"; _ }) ] ->
      ()
  | _ -> Alcotest.fail "expected padded stream provider error"

let test_message_runner_uses_eta_http_and_suppresses_transport_span () =
  with_traced_runtime @@ fun rt tracer ->
  let captured = ref None in
  let client =
    test_client ~with_http_span:true (response_of_fixture "message.json") captured
  in
  let response =
    run_ok rt "message runner"
      (O.messages client ~api_key:(A.api_key "sk-ant-test") (chat_request ()))
  in
  Alcotest.(check string) "text" "Sunny and 21C"
    (assistant_text response.message);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected eta-http request"
  in
  Alcotest.(check string) "method" "POST" request.H.Request.method_;
  Alcotest.(check string)
    "uri" "https://api.anthropic.com/v1/messages" request.uri;
  Alcotest.(check (option string))
    "auth" (Some "sk-ant-test")
    (H.Core.Header.get "x-api-key" request.headers);
  require_contains "request body tool schema"
    ~needle:"\"input_schema\":{\"type\":\"object\""
    (request_body_string request);
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool)
    "transport span suppressed" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
       spans);
  Alcotest.(check bool)
    "chat span emitted" true
    (List.exists
       (fun (span : Eta.Tracer.span) ->
         String.equal span.name "chat claude-3-5-sonnet-latest")
       spans)

let test_message_runner_provider_error () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let client =
    test_client (response_of_fixture ~status:529 ~headers "error.json") captured
  in
  match
    Eta.Runtime.run rt
      (O.messages client ~api_key:(A.api_key "sk-ant-test") (chat_request ()))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (A.Provider_error
          {
            provider = "anthropic";
            status = Some 529;
            code = Some "overloaded_error";
            message = "Overloaded";
            raw = Some _;
          })) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<ai-error>"))
        cause

let test_stream_runner_and_prompt_cache_header () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client =
    test_client (response_of_fixture ~headers "stream_tool.sse") captured
  in
  let prompt_cache = O.prompt_cache ~cache_system:true () in
  let events =
    run_ok rt "stream runner"
      (O.stream_messages ~prompt_cache client ~api_key:(A.api_key "sk-ant-test")
         (chat_request ())
      |> E.bind A.read_stream_events)
  in
  Alcotest.(check string)
    "streamed tool args" "{\"location\":\"Warsaw\"}" (stream_tool_args events);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected stream request"
  in
  require_contains "request stream true" ~needle:"\"stream\":true"
    (request_body_string request);
  require_contains "request cache control"
    ~needle:"\"cache_control\":{\"type\":\"ephemeral\"}"
    (request_body_string request);
  Alcotest.(check (option string))
    "prompt cache beta header" (Some "prompt-caching-2024-07-31")
    (H.Core.Header.get "anthropic-beta" request.headers)

let () =
  Alcotest.run "eta-ai-anthropic"
    [
      ( "provider",
        [
          Alcotest.test_case "value" `Quick test_provider_value;
          Alcotest.test_case "encode messages tools and cache" `Quick
            test_encode_messages_tools_and_cache;
          Alcotest.test_case "requires max tokens" `Quick
            test_encode_requires_max_tokens;
          Alcotest.test_case "user image does not reject" `Quick
            test_encode_user_image_does_not_reject;
          Alcotest.test_case "tool result with image does not crash" `Quick
            test_encode_tool_result_with_image_does_not_crash;
        ] );
      ( "decode",
        [
          Alcotest.test_case "message fixture" `Quick test_decode_message_fixture;
          Alcotest.test_case "tool fixture" `Quick test_decode_tool_fixture;
        ] );
      ( "streaming",
        [
          Alcotest.test_case "SSE fixture" `Quick test_stream_fixture;
          Alcotest.test_case "error fixture" `Quick test_stream_error_fixture;
          Alcotest.test_case "padded error JSON" `Quick
            test_stream_error_accepts_padded_json;
          Alcotest.test_case "stream runner and cache header" `Quick
            test_stream_runner_and_prompt_cache_header;
        ] );
      ( "http",
        [
          Alcotest.test_case "message runner" `Quick
            test_message_runner_uses_eta_http_and_suppresses_transport_span;
          Alcotest.test_case "provider error" `Quick
            test_message_runner_provider_error;
        ] );
    ]
