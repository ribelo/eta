module A = Eta_ai
module C = Eta_ai_openai_compat
module E = Eta.Effect
module H = Eta_http

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct

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

let chat_request ?(stream = false) ?(model = "mistral-large-latest") () :
    A.chat_request =
  {
    model;
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

let with_runtime f = B.with_runtime (fun _ctx rt -> f rt)

let with_traced_runtime f =
  B.with_traced_runtime (fun _ctx rt tracer -> f rt tracer)

let run_ok rt label eff =
  match B.run rt eff with
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
    ~stats:(fun () -> E.pure (Some zero_stats))
    ~shutdown:(fun () -> E.unit)

let request_body_string (request : H.Request.t) =
  match request.body with
  | H.Request.Fixed chunks ->
      chunks |> List.map Bytes.to_string |> String.concat ""
  | H.Request.Empty -> ""
  | H.Request.Stream _ | H.Request.Rewindable_stream _ ->
      Alcotest.fail "expected fixed request body"

let together_provider () =
  C.provider ~name:"together" ~base_url:"https://api.together.xyz" ()

let mistral_provider () =
  C.provider ~name:"mistral" ~base_url:"https://api.mistral.ai"
    ~auth:(C.bearer_auth ())
    ~extra_headers:[ ("X-Provider-Trace", "fixture") ]
    ()

let raw_auth_provider () =
  C.provider ~name:"internal-compatible"
    ~base_url:"https://llm.internal.example"
    ~auth:(C.raw_header_auth ~header:"X-API-Key" ())
    ~chat_path:"/chat/completions"
    ()

let test_provider_configuration () =
  let provider = together_provider () in
  Alcotest.(check string) "name" "together" provider.A.name;
  Alcotest.(check string)
    "base url" "https://api.together.xyz" provider.base_url;
  Alcotest.(check string)
    "path" "/v1/chat/completions" provider.chat_path;
  let headers = provider.auth_headers (A.api_key "tk-test") in
  Alcotest.(check (option string))
    "bearer" (Some "Bearer tk-test")
    (H.Core.Header.get "authorization" headers);
  let raw = raw_auth_provider () in
  let headers = raw.auth_headers (A.api_key "raw-test") in
  Alcotest.(check (option string))
    "raw key" (Some "raw-test")
    (H.Core.Header.get "x-api-key" headers);
  Alcotest.(check string) "custom path" "/chat/completions" raw.chat_path

let test_request_uses_compatible_endpoint_and_extra_headers () =
  let provider = mistral_provider () in
  let output =
    C.structured_output ~name:"weather_answer" ~schema_json:weather_schema
      ~strict:true ()
    |> expect_ok "structured output"
  in
  Alcotest.(check string)
    "cached schema" weather_schema (A.Json.compact output.schema);
  let request =
    C.chat_completions_request ~structured_output:output ~provider
      ~api_key:(A.api_key "mk-test") (chat_request ())
    |> expect_ok "compat request"
  in
  Alcotest.(check string)
    "uri" "https://api.mistral.ai/v1/chat/completions" request.uri;
  Alcotest.(check (option string))
    "auth" (Some "Bearer mk-test")
    (H.Core.Header.get "authorization" request.headers);
  Alcotest.(check (option string))
    "extra header" (Some "fixture")
    (H.Core.Header.get "x-provider-trace" request.headers);
  require_contains "openai-compatible body"
    ~needle:"\"messages\":[" (request_body_string request);
  require_contains "tool schema"
    ~needle:"\"parameters\":{\"type\":\"object\""
    (request_body_string request);
  require_contains "structured output"
    ~needle:"\"response_format\":{\"type\":\"json_schema\""
    (request_body_string request);
  require_contains "structured output strict" ~needle:"\"strict\":true"
    (request_body_string request)

let test_decode_compatible_fixtures () =
  let text =
    C.decode_chat (read_fixture "together_chat.json")
    |> expect_ok "together chat"
  in
  Alcotest.(check string) "text" "Compatible response"
    (assistant_text text.message);
  let tool =
    C.decode_chat (read_fixture "mistral_tool.json")
    |> expect_ok "mistral tool"
  in
  match assistant_tool_calls tool.message with
  | [ call ] ->
      Alcotest.(check string) "tool" "weather" call.name;
      Alcotest.(check string)
        "arguments" "{\"location\":\"Warsaw\"}" call.arguments_json
  | _ -> Alcotest.fail "expected one tool call"

let test_decode_missing_choices_fails () =
  let raw = "{\"id\":\"bad\",\"model\":\"fixture\"}" in
  match C.decode_chat raw with
  | Error
      (A.Decode_error
        {
          provider = "openai-compatible";
          message = "chat completion missing choices";
          raw = Some actual;
        }) ->
      Alcotest.(check string) "raw" raw actual
  | Ok _ -> Alcotest.fail "missing choices decoded successfully"
  | Error _ -> Alcotest.fail "unexpected error"

let test_runner_suppresses_transport_span () =
  with_traced_runtime @@ fun rt tracer ->
  let captured = ref None in
  let client =
    test_client ~with_http_span:true
      (response_of_fixture "together_chat.json")
      captured
  in
  let provider = together_provider () in
  let response =
    run_ok rt "compat runner"
      (C.chat_completions ~provider client ~api_key:(A.api_key "tk-test")
         (chat_request ~model:"meta-llama/Llama-3.3-70B-Instruct-Turbo" ()))
  in
  Alcotest.(check string) "text" "Compatible response"
    (assistant_text response.message);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected request"
  in
  Alcotest.(check string)
    "uri" "https://api.together.xyz/v1/chat/completions" request.uri;
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool)
    "transport span suppressed" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
       spans);
  Alcotest.(check bool)
    "chat span provider model" true
    (List.exists
       (fun (span : Eta.Tracer.span) ->
         String.equal span.name
           "chat meta-llama/Llama-3.3-70B-Instruct-Turbo")
       spans)

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

let has_done events =
  List.exists (function A.Stream_done -> true | _ -> false) events

let test_stream_runner () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client = test_client (response_of_fixture ~headers "stream.sse") captured in
  let provider = mistral_provider () in
  let events =
    run_ok rt "compat stream"
      (C.stream_chat_completions ~provider client ~api_key:(A.api_key "mk-test")
         (chat_request ())
      |> E.bind A.read_stream_events)
  in
  Alcotest.(check string) "text" "Hello" (stream_text events);
  Alcotest.(check string)
    "tool args" "{\"location\":\"Warsaw\"}" (stream_tool_args events);
  Alcotest.(check bool) "done" true (has_done events);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected stream request"
  in
  require_contains "stream true" ~needle:"\"stream\":true"
    (request_body_string request)

let test_provider_error () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let client =
    test_client (response_of_fixture ~status:404 ~headers "error.json") captured
  in
  let provider = mistral_provider () in
  match
    B.run rt
      (C.chat_completions ~provider client ~api_key:(A.api_key "mk-test")
         (chat_request ()))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (A.Provider_error
          {
            provider = "mistral";
            status = Some 404;
            code = Some "model_not_found";
            message = "Invalid model";
            raw = Some _;
          })) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<ai-error>"))
        cause

let tests =
  [
      ( "provider",
        [
          Alcotest.test_case "configuration" `Quick
            test_provider_configuration;
          Alcotest.test_case "request endpoint and headers" `Quick
            test_request_uses_compatible_endpoint_and_extra_headers;
        ] );
      ( "fixtures",
        [
          Alcotest.test_case "decode compatible fixtures" `Quick
            test_decode_compatible_fixtures;
          Alcotest.test_case "missing choices decode error" `Quick
            test_decode_missing_choices_fails;
        ] );
      ( "http",
        [
          Alcotest.test_case "runner suppression" `Quick
            test_runner_suppresses_transport_span;
          Alcotest.test_case "stream runner" `Quick test_stream_runner;
          Alcotest.test_case "provider error" `Quick test_provider_error;
        ] );
  ]
end
