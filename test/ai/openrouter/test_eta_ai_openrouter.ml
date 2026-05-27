module A = Eta_ai
module O = Eta_ai_openrouter
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

let chat_request ?(stream = false) () : A.chat_request =
  {
    model = "openrouter/auto";
    prompt = [ A.User [ A.Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    stream;
  }

let assistant_text = function
  | A.Assistant { content; _ } ->
      content
      |> List.filter_map (function
           | A.Text text -> Some text
           | A.Json _ | A.Audio _ -> None)
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
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f rt tracer

let run_ok rt label effect =
  match Eta.Runtime.run rt effect with
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
    let effect = E.pure response in
    if with_http_span then
      E.named_kind ~kind:Eta.Capabilities.Client "HTTP POST" effect
    else effect
  in
  H.Client.make_for_test ~protocol:H.Client.H1 ~request
    ~stats:(fun () -> E.pure zero_stats)
    ~shutdown:(fun () -> E.unit)

let request_body_string (request : H.Request.t) =
  match request.body with
  | H.Request.Fixed chunks ->
      chunks |> List.map Bytes.to_string |> String.concat ""
  | H.Request.Empty -> ""
  | H.Request.Stream _ | H.Request.Rewindable_stream _ ->
      Alcotest.fail "expected fixed request body"

let routing () =
  O.routing ~order:[ "anthropic"; "openai" ] ~ignored_providers:[ "bad" ]
    ~allow_fallbacks:true ~require_parameters:true ~sort:"throughput" ()
  |> expect_ok "routing"

let provider () =
  let attribution =
    O.attribution ~referer:"https://eta.example" ~title:"Eta Tests" ()
  in
  O.provider ~attribution ~extra_headers:[ ("X-Debug", "fixture") ] ()

let test_provider_headers () =
  let provider = provider () in
  Alcotest.(check string) "name" "openrouter" provider.name;
  Alcotest.(check string)
    "base" "https://openrouter.ai" provider.base_url;
  Alcotest.(check string)
    "path" "/api/v1/responses" provider.chat_path;
  let headers = provider.auth_headers (A.api_key "or-test") in
  Alcotest.(check (option string))
    "auth" (Some "Bearer or-test")
    (H.Core.Header.get "authorization" headers);
  Alcotest.(check (option string))
    "referer" (Some "https://eta.example")
    (H.Core.Header.get "http-referer" headers);
  Alcotest.(check (option string))
    "title" (Some "Eta Tests") (H.Core.Header.get "x-title" headers);
  Alcotest.(check (option string))
    "extra" (Some "fixture") (H.Core.Header.get "x-debug" headers)

let test_encode_routing_and_rejects_empty_provider () =
  let output =
    O.structured_output ~name:"weather_answer" ~schema_json:weather_schema
      ~strict:true ()
    |> expect_ok "structured output"
  in
  let raw =
    O.encode_chat ~structured_output:output ~routing:(routing ())
      (chat_request ())
    |> expect_ok "openrouter encode"
  in
  require_contains "provider object" ~needle:"\"provider\":{" raw;
  require_contains "fallback order"
    ~needle:"\"order\":[\"anthropic\",\"openai\"]" raw;
  require_contains "ignored providers" ~needle:"\"ignore\":[\"bad\"]" raw;
  require_contains "fallbacks" ~needle:"\"allow_fallbacks\":true" raw;
  require_contains "require params" ~needle:"\"require_parameters\":true" raw;
  require_contains "sort" ~needle:"\"sort\":\"throughput\"" raw;
  require_contains "responses input" ~needle:"\"input\":[" raw;
  require_contains "responses max tokens" ~needle:"\"max_output_tokens\":64" raw;
  require_contains "structured output"
    ~needle:"\"text\":{\"format\":{\"type\":\"json_schema\"" raw;
  require_contains "structured output strict" ~needle:"\"strict\":true" raw;
  match O.routing ~order:[ "anthropic"; "" ] () with
  | Stdlib.Error (A.Unsupported { provider = "openrouter"; _ }) -> ()
  | _ -> Alcotest.fail "expected empty provider rejection"

let test_request_uses_openrouter_endpoint () =
  let request =
    O.responses_request ~routing:(routing ()) ~provider:(provider ())
      ~api_key:(A.api_key "or-test") (chat_request ())
    |> expect_ok "request"
  in
  Alcotest.(check string)
    "uri" "https://openrouter.ai/api/v1/responses" request.uri;
  require_contains "routing body" ~needle:"\"provider\":{"
    (request_body_string request)

let test_decode_responses_fixtures () =
  let text = O.decode_responses (read_fixture "chat.json") |> expect_ok "chat" in
  Alcotest.(check string) "text" "OpenRouter response"
    (assistant_text text.message);
  let tool = O.decode_responses (read_fixture "tool.json") |> expect_ok "tool" in
  match assistant_tool_calls tool.message with
  | [ call ] ->
      Alcotest.(check string) "tool name" "weather" call.name;
      Alcotest.(check string)
        "arguments" "{\"location\":\"Warsaw\"}" call.arguments_json
  | _ -> Alcotest.fail "expected one tool call"

let stream_text events =
  events
  |> List.filter_map (function
       | A.Stream_content_delta text -> Some text
       | _ -> None)
  |> String.concat ""

let stream_errors events =
  events
  |> List.filter_map (function
       | A.Stream_error (A.Provider_error { message; _ }) -> Some message
       | _ -> None)

let test_stream_midstream_error_fixture () =
  with_runtime @@ fun rt ->
  let stream =
    A.stream_of_body (O.provider ()) (body_of_fixture "stream_error.sse")
  in
  let events = run_ok rt "stream" (A.read_stream_events stream) in
  Alcotest.(check string) "text before error" "partial" (stream_text events);
  Alcotest.(check (list string))
    "errors" [ "Provider disconnected" ] (stream_errors events)

let test_runner_suppresses_transport_span () =
  with_traced_runtime @@ fun rt tracer ->
  let captured = ref None in
  let client =
    test_client ~with_http_span:true (response_of_fixture "chat.json") captured
  in
  let response =
    run_ok rt "runner"
      (O.responses ~routing:(routing ()) ~provider:(provider ()) client
         ~api_key:(A.api_key "or-test") (chat_request ()))
  in
  Alcotest.(check string) "text" "OpenRouter response"
    (assistant_text response.message);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected request"
  in
  require_contains "request routing" ~needle:"\"provider\":{"
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
         String.equal span.name "chat openrouter/auto")
       spans)

let test_provider_error () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let client =
    test_client (response_of_fixture ~status:502 ~headers "error.json") captured
  in
  match
    Eta.Runtime.run rt
      (O.responses ~provider:(provider ()) client
         ~api_key:(A.api_key "or-test") (chat_request ()))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (A.Provider_error
          {
            provider = "openrouter";
            status = Some 502;
            code = Some "502";
            message = "Provider disconnected";
            raw = Some _;
          })) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<ai-error>"))
        cause

let test_stream_runner () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client =
    test_client (response_of_fixture ~headers "stream_error.sse") captured
  in
  let events =
    run_ok rt "stream runner"
      (O.stream_responses ~routing:(routing ()) ~provider:(provider ())
         client ~api_key:(A.api_key "or-test") (chat_request ())
      |> E.bind A.read_stream_events)
  in
  Alcotest.(check string) "text before error" "partial" (stream_text events);
  Alcotest.(check (list string))
    "errors" [ "Provider disconnected" ] (stream_errors events);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected stream request"
  in
  require_contains "stream true" ~needle:"\"stream\":true"
    (request_body_string request);
  require_contains "routing body" ~needle:"\"provider\":{"
    (request_body_string request)

let () =
  Alcotest.run "eta-ai-openrouter"
    [
      ( "provider",
        [
          Alcotest.test_case "headers" `Quick test_provider_headers;
          Alcotest.test_case "encode routing" `Quick
            test_encode_routing_and_rejects_empty_provider;
          Alcotest.test_case "request endpoint" `Quick
            test_request_uses_openrouter_endpoint;
        ] );
      ( "fixtures",
        [
          Alcotest.test_case "decode responses fixtures" `Quick
            test_decode_responses_fixtures;
          Alcotest.test_case "midstream error" `Quick
            test_stream_midstream_error_fixture;
        ] );
      ( "http",
        [
          Alcotest.test_case "runner suppression" `Quick
            test_runner_suppresses_transport_span;
          Alcotest.test_case "provider error" `Quick test_provider_error;
          Alcotest.test_case "stream runner" `Quick test_stream_runner;
        ] );
    ]
