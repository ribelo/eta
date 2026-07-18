module A = Eta_ai
module O = Eta_ai_openai
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

let expect_unsupported label = function
  | Stdlib.Error (A.Unsupported { feature; _ }) -> feature
  | Stdlib.Error _ -> Alcotest.fail ("expected Unsupported: " ^ label)
  | Stdlib.Ok _ -> Alcotest.fail ("expected Error: " ^ label)

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
    model = "gpt-4o-mini";
    prompt = [ A.System "stay brief"; A.User [ A.Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    replay_items = [];
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

let response_of_bytes ?(status = 200) ?(headers = []) body =
  H.Response.make ~status ~headers
    ~body:(H.Body.Stream.of_bytes [ Bytes.of_string body ])
    ()

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

let multipart_boundary (request : H.Request.t) =
  match H.Core.Header.get "content-type" request.headers with
  | Some header ->
      let prefix = "multipart/form-data; boundary=" in
      let prefix_len = String.length prefix in
      if
        String.length header >= prefix_len
        && String.sub header 0 prefix_len = prefix
      then String.sub header prefix_len (String.length header - prefix_len)
      else Alcotest.failf "unexpected multipart content-type: %s" header
  | None -> Alcotest.fail "missing multipart content-type"

let test_provider_value () =
  let provider = O.provider ~base_url:"https://api.openai.test" () in
  Alcotest.(check string) "name" "openai" provider.name;
  Alcotest.(check string) "path" "/v1/responses" provider.chat_path;
  let chat_provider =
    O.chat_completions_provider ~base_url:"https://api.openai.test" ()
  in
  Alcotest.(check string)
    "legacy path" "/v1/chat/completions" chat_provider.chat_path;
  Alcotest.(check bool) "streaming" true provider.capabilities.streaming;
  Alcotest.(check bool) "tools" true provider.capabilities.tools;
  Alcotest.(check bool) "image input" true provider.capabilities.image_input;
  Alcotest.(check bool) "audio prompt input" false provider.capabilities.audio_input;
  Alcotest.(check bool) "video prompt input" false provider.capabilities.video_input;
  Alcotest.(check bool) "image generation" true provider.capabilities.image_generation;
  Alcotest.(check bool) "speech" true provider.capabilities.speech;
  Alcotest.(check bool) "transcription" true provider.capabilities.transcription;
  let headers = provider.auth_headers (A.api_key "sk-test") in
  Alcotest.(check (option string))
    "authorization" (Some "Bearer sk-test")
    (H.Core.Header.get "authorization" headers)

let test_encode_chat_and_responses () =
  let output =
    O.structured_output ~name:"weather_answer" ~schema_json:weather_schema
      ~strict:true ()
    |> expect_ok "structured output"
  in
  let chat =
    O.encode_chat ~structured_output:output (chat_request ()) |> expect_ok "chat"
  in
  require_contains "chat model" ~needle:"\"model\":\"gpt-4o-mini\"" chat;
  require_contains "chat messages" ~needle:"\"messages\":[" chat;
  require_contains "tool function" ~needle:"\"type\":\"function\"" chat;
  require_contains "raw parameters"
    ~needle:"\"parameters\":{\"type\":\"object\"" chat;
  require_contains "response format"
    ~needle:"\"response_format\":{\"type\":\"json_schema\"" chat;
  let responses =
    O.encode_responses ~structured_output:output (chat_request ())
    |> expect_ok "responses"
  in
  require_contains "responses input" ~needle:"\"input\":[" responses;
  require_contains "responses tools" ~needle:"\"tools\":[" responses;
  require_contains "responses text format"
    ~needle:"\"text\":{\"format\":{\"type\":\"json_schema\"" responses;
  require_contains "responses max tokens"
    ~needle:"\"max_output_tokens\":64" responses;
  let tool_output_request =
    {
      (chat_request ()) with
      prompt =
        [
          A.User [ A.Text "weather in Warsaw" ];
          A.Tool
            {
              tool_call_id = "call_weather";
              content = [ A.Text "{\"temperature\":21}" ];
            };
        ];
    }
  in
  let responses = O.encode_responses tool_output_request |> expect_ok "tool output" in
  require_contains "function call output"
    ~needle:"\"type\":\"function_call_output\"" responses

let test_decode_chat_fixture () =
  let response =
    O.decode_chat (read_fixture "chat_completion.json")
    |> expect_ok "chat completion fixture"
  in
  Alcotest.(check (option string)) "id" (Some "chatcmpl_fixture") response.id;
  Alcotest.(check string) "text" "Sunny and 68F"
    (assistant_text response.message);
  Alcotest.(check bool) "stop" true
    (List.exists (function A.Stop -> true | _ -> false) response.finish_reasons);
  Alcotest.(check (option int))
    "input tokens" (Some 11)
    (Option.bind response.usage (fun usage -> usage.A.input_tokens.total))

let test_decode_chat_rejects_fractional_usage_integer () =
  let raw =
    {|{"id":"chatcmpl_fractional","model":"gpt-fixture","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1.5,"completion_tokens":2,"total_tokens":3}}|}
  in
  let response = O.decode_chat raw |> expect_ok "fractional usage" in
  Alcotest.(check (option int)) "fractional prompt tokens rejected" None
    (Option.bind response.usage (fun usage -> usage.A.input_tokens.total));
  Alcotest.(check (option int)) "integral completion tokens kept" (Some 2)
    (Option.bind response.usage (fun usage -> usage.A.output_tokens.total))

let test_decode_chat_usage_details () =
  let raw =
    {|{"id":"chatcmpl_usage","model":"gpt-fixture","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":8,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":4},"completion_tokens_details":{"reasoning_tokens":3}}}|}
  in
  let response = O.decode_chat raw |> expect_ok "chat usage details" in
  let usage = Option.get response.usage in
  Alcotest.(check (option int)) "uncached input" (Some 6)
    usage.A.input_tokens.uncached;
  Alcotest.(check (option int)) "total input" (Some 10)
    usage.A.input_tokens.total;
  Alcotest.(check (option int)) "cache read" (Some 4)
    usage.A.input_tokens.cache_read;
  Alcotest.(check (option int)) "total output" (Some 8)
    usage.A.output_tokens.total;
  Alcotest.(check (option int)) "text output" (Some 5)
    usage.A.output_tokens.text;
  Alcotest.(check (option int)) "reasoning output" (Some 3)
    usage.A.output_tokens.reasoning

let test_decode_tool_fixture () =
  let response =
    O.decode_chat (read_fixture "chat_tool_completion.json")
    |> expect_ok "tool completion fixture"
  in
  match assistant_tool_calls response.message with
  | [ call ] ->
      Alcotest.(check string) "id" "call_weather" call.id;
      Alcotest.(check string) "name" "weather" call.name;
      Alcotest.(check string)
        "arguments" "{\"location\":\"Warsaw\"}" call.arguments_json;
      Alcotest.(check bool) "tool finish" true
        (List.exists
           (function A.Tool_calls -> true | _ -> false)
           response.finish_reasons)
  | _ -> Alcotest.fail "expected one tool call"

let test_decode_responses_fixture () =
  let response =
    O.decode_responses (read_fixture "responses.json")
    |> expect_ok "responses fixture"
  in
  Alcotest.(check (option string)) "id" (Some "resp_fixture") response.id;
  Alcotest.(check string) "text" "It is 21C in Warsaw."
    (assistant_text response.message);
  match assistant_tool_calls response.message with
  | [ call ] ->
      Alcotest.(check string) "call id" "call_weather" call.id;
      Alcotest.(check string) "call name" "weather" call.name
  | _ -> Alcotest.fail "expected responses function call"

let test_decode_responses_failed_status_is_error () =
  let raw =
    {|
    {
      "id": "resp_1",
      "model": "gpt-test",
      "status": "failed",
      "error": { "code": "server_error", "message": "model crashed" },
      "output": []
    }
    |}
  in
  match O.decode_responses raw with
  | Error (A.Provider_error { code = Some "server_error"; message; _ }) ->
      Alcotest.(check string) "message" "model crashed" message
  | Error other ->
      Alcotest.failf "wrong error constructor: %s"
        (match other with
        | A.Provider_error _ -> "provider"
        | A.Decode_error _ -> "decode"
        | A.Unsupported _ -> "unsupported"
        | A.Invalid_tool _ -> "invalid_tool"
        | A.Eta_http_error _ -> "http")
  | Ok response ->
      Alcotest.failf
        "failed provider response decoded as Ok; finish_reasons length=%d"
        (List.length response.finish_reasons)

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

let test_responses_stream_preserves_function_call_name () =
  let added : A.sse_event =
    {
      event = Some "response.output_item.added";
      data =
        {|
        {
          "type": "response.output_item.added",
          "output_index": 0,
          "item": {
            "type": "function_call",
            "id": "fc_1",
            "call_id": "call_1",
            "name": "lookup",
            "arguments": ""
          }
        }
        |};
    }
  in
  match O.decode_stream_event added with
  | Stdlib.Ok
      [
        A.Stream_tool_call_delta
          {
            index = Some 0;
            id = Some "call_1";
            name = Some "lookup";
            arguments_json_delta = "";
          };
      ] ->
      ()
  | Stdlib.Ok events ->
      Alcotest.failf
        "function-call metadata event was dropped or incomplete; got %d events"
        (List.length events)
  | Stdlib.Error _ ->
      Alcotest.fail
        "decoder rejected a valid Responses function-call metadata event"

let test_stream_done_allows_surrounding_whitespace () =
  match O.decode_stream_event { A.event = None; data = " \n[DONE]\t" } with
  | Stdlib.Ok [ A.Stream_done ] -> ()
  | Stdlib.Ok events ->
      Alcotest.failf "expected stream done; got %d events" (List.length events)
  | Stdlib.Error _ -> Alcotest.fail "decoder rejected padded stream done"

let test_stream_fixture () =
  with_runtime @@ fun rt ->
  let stream =
    A.stream_of_body (O.provider ()) (body_of_fixture "responses_stream.sse")
  in
  let events = run_ok rt "read stream fixture" (A.read_stream_events stream) in
  Alcotest.(check string) "text" "The weather is " (stream_text events);
  Alcotest.(check string)
    "tool args" "{\"location\":\"Warsaw\"}" (stream_tool_args events);
  Alcotest.(check bool) "done" true (has_done events)

let test_responses_runner_uses_eta_http_and_suppresses_transport_span () =
  with_traced_runtime @@ fun rt tracer ->
  let captured = ref None in
  let client =
    test_client ~with_http_span:true
      (response_of_fixture "responses.json")
      captured
  in
  let response =
    run_ok rt "responses runner"
      (O.responses client ~api_key:(A.api_key "sk-test") (chat_request ()))
  in
  Alcotest.(check string) "text" "It is 21C in Warsaw."
    (assistant_text response.message);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected eta-http request"
  in
  Alcotest.(check string)
    "method" "POST" request.H.Request.method_;
  Alcotest.(check string)
    "uri" "https://api.openai.com/v1/responses" request.uri;
  Alcotest.(check (option string))
    "auth" (Some "Bearer sk-test")
    (H.Core.Header.get "authorization" request.headers);
  require_contains "request body tool schema"
    ~needle:"\"parameters\":{\"type\":\"object\""
    (request_body_string request);
  require_contains "request body input" ~needle:"\"input\":["
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
       (fun (span : Eta.Tracer.span) -> String.equal span.name "chat gpt-4o-mini")
       spans)

let test_responses_runner_provider_error () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list
      [ ("content-type", "application/json"); ("Retry-After", "9") ]
  in
  let client =
    test_client
      (response_of_fixture ~status:429 ~headers "error.json")
      captured
  in
  match
    B.run rt
      (O.responses client ~api_key:(A.api_key "sk-test") (chat_request ()))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (A.Provider_error
          {
            provider = "openai";
            status = Some 429;
            code = Some "rate_limit_exceeded";
            message = "Rate limit reached";
            raw = Some _;
            retry_after_s = Some 9;
          } as error)) ->
      let failure = A.project_ai_error error in
      Alcotest.(check string)
        "category" "transient"
        (A.ai_error_category_to_string failure.category);
      Alcotest.(check bool) "retryable" true failure.retryable;
      Alcotest.(check (option int)) "retry after" (Some 9)
        failure.retry_after_s;
      Alcotest.(check bool) "message retained in diagnostic" true
        (contains ~needle:"Rate limit reached" failure.diagnostic);
      Alcotest.(check bool) "raw body omitted from diagnostic" false
        (contains ~needle:"raw=" failure.diagnostic)
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<ai-error>"))
        cause

let test_openai_decode_error_projects_categories () =
  let headers =
    H.Core.Header.unsafe_of_list
      [ ("content-type", "application/json"); ("retry-after", "15") ]
  in
  let rate_limit =
    O.decode_error ~status:429 ~headers
      "{\"error\":{\"message\":\"Rate limit reached\",\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}"
  in
  (match rate_limit with
  | A.Provider_error { retry_after_s = Some 15; code = Some "rate_limit_exceeded"; _ }
    ->
      let failure = A.project_ai_error rate_limit in
      Alcotest.(check string)
        "rate limit category" "transient"
        (A.ai_error_category_to_string failure.category);
      Alcotest.(check bool) "rate limit retryable" true failure.retryable
  | _ -> Alcotest.fail "expected rate limit provider error");
  let quota =
    O.decode_error ~status:429 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"You exceeded your current quota\",\"code\":\"insufficient_quota\"}}"
  in
  let quota_failure = A.project_ai_error quota in
  Alcotest.(check string)
    "quota category" "quota_budget"
    (A.ai_error_category_to_string quota_failure.category);
  Alcotest.(check bool) "quota not retryable" false quota_failure.retryable;
  let context =
    O.decode_error ~status:400 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens\",\"code\":\"context_length_exceeded\"}}"
  in
  let context_failure = A.project_ai_error context in
  Alcotest.(check string)
    "context category" "context_overflow"
    (A.ai_error_category_to_string context_failure.category);
  Alcotest.(check bool) "context not retryable" false context_failure.retryable;
  let billing =
    O.decode_error ~status:400 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"Billing hard limit reached\",\"code\":\"billing_hard_limit_reached\"}}"
  in
  let billing_failure = A.project_ai_error billing in
  Alcotest.(check string)
    "billing category" "billing"
    (A.ai_error_category_to_string billing_failure.category);
  Alcotest.(check bool) "billing not retryable" false billing_failure.retryable;
  Alcotest.(check bool) "code retained in diagnostic" true
    (contains ~needle:"billing_hard_limit_reached" billing_failure.diagnostic);
  Alcotest.(check bool) "diagnostic omits raw json body" false
    (contains ~needle:"{\"error\"" billing_failure.diagnostic)

let test_stream_runner () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client =
    test_client
      (response_of_fixture ~headers "responses_stream.sse")
      captured
  in
  let events =
    run_ok rt "stream runner"
      (O.stream_responses client ~api_key:(A.api_key "sk-test")
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
  require_contains "request input" ~needle:"\"input\":["
    (request_body_string request)

let test_responses_request_uses_responses_endpoint () =
  let request =
    O.responses_request ~api_key:(A.api_key "sk-test") (chat_request ())
    |> expect_ok "responses request"
  in
  Alcotest.(check string)
    "responses uri" "https://api.openai.com/v1/responses" request.uri;
  require_contains "responses body" ~needle:"\"input\":["
    (request_body_string request)

let embedding_request () : A.Embedding.request =
  {
    model = "text-embedding-3-small";
    input = A.Embedding.Text "hello eta";
    encoding_format = Some "float";
    dimensions = Some 3;
    user = Some "eta-test";
  }

let test_embeddings_request_and_decode () =
  let request =
    O.embeddings_request ~api_key:(A.api_key "sk-test") (embedding_request ())
    |> expect_ok "embeddings request"
  in
  Alcotest.(check string)
    "uri" "https://api.openai.com/v1/embeddings" request.uri;
  require_contains "embedding model"
    ~needle:"\"model\":\"text-embedding-3-small\""
    (request_body_string request);
  let response =
    O.decode_embeddings (read_fixture "embeddings.json")
    |> expect_ok "embeddings fixture"
  in
  Alcotest.(check int) "embedding count" 1 (List.length response.embeddings)

let test_image_generation_request_and_decode () =
  let request =
    O.image_generation_request ~api_key:(A.api_key "sk-test")
      {
        A.Image.model = Some "gpt-image-1";
        prompt = "draw eta";
        n = Some 1;
        size = Some "1024x1024";
        quality = None;
        response_format = Some "url";
        user = None;
        extra = [];
      }
    |> expect_ok "image request"
  in
  Alcotest.(check string)
    "uri" "https://api.openai.com/v1/images/generations" request.uri;
  let response =
    O.decode_image_response (read_fixture "image_generation.json")
    |> expect_ok "image fixture"
  in
  match response.images with
  | image :: _ ->
      Alcotest.(check (option string))
        "image url" (Some "https://example.test/image.png")
        image.url
  | [] -> Alcotest.fail "expected generated image"

let test_speech_runner () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let client =
    test_client
      (response_of_bytes ~headers:[ ("Content-Type", "audio/mpeg") ] "MP3")
      captured
  in
  let response =
    run_ok rt "speech runner"
      (O.speech client ~api_key:(A.api_key "sk-test")
         {
           A.Speech.model = "gpt-4o-mini-tts";
           input = "hello";
           voice = "alloy";
           response_format = Some "mp3";
           speed = Some 1.0;
           instructions = None;
           extra = [];
         })
  in
  Alcotest.(check string) "speech body" "MP3" (Bytes.to_string response.audio);
  match !captured with
  | Some request ->
      Alcotest.(check string)
        "uri" "https://api.openai.com/v1/audio/speech" request.uri
  | None -> Alcotest.fail "expected speech request"

let test_transcription_request_and_decode () =
  let request =
    O.transcription_request ~api_key:(A.api_key "sk-test")
      {
        A.Transcription.model = "gpt-4o-transcribe";
        file =
          { filename = "sample.wav"; content_type = "audio/wav"; data = Bytes.of_string "RIFF" };
        language = Some "en";
        prompt = None;
        response_format = Some "json";
        temperature = Some 0.0;
        extra_fields = [];
      }
    |> expect_ok "transcription request"
  in
  Alcotest.(check string)
    "uri" "https://api.openai.com/v1/audio/transcriptions" request.uri;
  Alcotest.(check bool)
    "multipart" true
    (Option.is_some (H.Core.Header.get "content-type" request.headers));
  let response =
    O.decode_transcription_response (read_fixture "transcription.json")
    |> expect_ok "transcription fixture"
  in
  Alcotest.(check (option string)) "text" (Some "hello eta") response.text

let test_transcription_request_rejects_multipart_header_injection () =
  let make_request ?(content_type = "audio/wav") ?(extra_fields = []) () =
    {
      A.Transcription.model = "gpt-4o-transcribe";
      file =
        {
          filename = "sample.wav";
          content_type;
          data = Bytes.of_string "RIFF";
        };
      language = None;
      prompt = None;
      response_format = None;
      temperature = None;
      extra_fields;
    }
  in
  let field_error =
    O.transcription_request ~api_key:(A.api_key "sk-test")
      (make_request ~extra_fields:[ ("bad\r\nname", "value") ] ())
    |> expect_unsupported "transcription extra field name"
  in
  require_contains "field name error" ~needle:"field name" field_error;
  let content_type_error =
    O.transcription_request ~api_key:(A.api_key "sk-test")
      (make_request ~content_type:"audio/wav\r\nX-Injected: yes" ())
    |> expect_unsupported "transcription content type"
  in
  require_contains "content type error" ~needle:"content type"
    content_type_error

let test_transcription_request_avoids_boundary_collision () =
  let data = Bytes.of_string "RIFF" in
  let digest_boundary = "eta-ai-" ^ Digest.to_hex (Digest.bytes data) in
  let request =
    O.transcription_request ~api_key:(A.api_key "sk-test")
      {
        A.Transcription.model = "gpt-4o-transcribe";
        file = { filename = "sample.wav"; content_type = "audio/wav"; data };
        language = None;
        prompt = Some ("please transcribe --" ^ digest_boundary);
        response_format = None;
        temperature = None;
        extra_fields = [];
      }
    |> expect_ok "transcription request"
  in
  let boundary = multipart_boundary request in
  Alcotest.(check bool)
    "boundary changed away from colliding digest" true
    (not (String.equal digest_boundary boundary));
  Alcotest.(check bool)
    "prompt does not contain chosen boundary" false
    (contains ~needle:boundary ("please transcribe --" ^ digest_boundary));
  ignore (request_body_string request : string)

let test_chat_and_responses_encode_audio_content () =
  let request =
    { (chat_request ()) with prompt = [ A.User [ A.audio_pcm16_base64 "AAE=" ] ] }
  in
  let raw = O.encode_responses request |> expect_ok "audio responses" in
  require_contains "audio part" ~needle:"\"type\":\"input_audio\"" raw;
  require_contains "audio data" ~needle:"\"data\":\"AAE=\"" raw

let test_openai_image_content_wire_shape () =
  (* OpenAI Chat Completions image content parts must use:
     { "type": "image_url", "image_url": { "url": "...", "detail": ... } }
     The current codec emits:
     { "type": "url", "url": { "url": "...", "detail": ... } }
     which is the wrong wire shape and will be rejected by the API. *)
  let request : A.chat_request =
    {
      model = "gpt-4o";
      prompt =
        [
          A.User
            [
              A.Text "What is in this image?";
              A.Image { url = "https://example.com/cat.png"; detail = Some "low" };
            ];
        ];
      tools = [];
      temperature = None;
      max_output_tokens = Some 100;
      replay_items = [];
      stream = false;
    }
  in
  let raw = O.encode_chat request |> expect_ok "image chat" in
  (* The wire format MUST contain "image_url" as the type *)
  require_contains "image type" ~needle:"\"type\":\"image_url\"" raw;
  require_contains "image_url field" ~needle:"\"image_url\":{" raw

let test_realtime_session_json () =
  let session =
    O.Realtime.session ~model:"gpt-realtime-2" ~instructions:"stay brief"
      ~input_audio_format:A.Pcm16 ~output_audio_format:A.G711_ulaw ~voice:"verse"
      ~max_output_tokens:128 ()
  in
  let raw = O.Realtime.session_to_string session in
  require_contains "realtime type" ~needle:"\"type\":\"realtime\"" raw;
  require_contains "modalities" ~needle:"\"output_modalities\":[\"text\",\"audio\"]" raw;
  require_contains "pcm format" ~needle:"\"type\":\"audio/pcm\"" raw;
  require_contains "ulaw format" ~needle:"\"type\":\"audio/pcmu\"" raw;
  require_contains "voice" ~needle:"\"voice\":\"verse\"" raw

let test_realtime_client_secret_request () =
  let session = O.Realtime.session ~model:"gpt-realtime-2" () in
  let request =
    O.Realtime.client_secret_request ~base_url:"https://api.openai.test"
      ~api_key:(A.api_key "sk-test") session
  in
  Alcotest.(check string)
    "uri" "https://api.openai.test/v1/realtime/client_secrets" request.uri;
  Alcotest.(check (option string))
    "auth" (Some "Bearer sk-test")
    (H.Core.Header.get "authorization" request.headers);
  require_contains "session body" ~needle:"\"session\":{" (request_body_string request)

let test_realtime_client_event_audio_append () =
  let audio =
    match A.audio_pcm16_base64 "AAECAw==" with
    | A.Audio audio -> audio
    | _ -> Alcotest.fail "expected audio"
  in
  let raw =
    O.Realtime.client_event_to_string (O.Realtime.Input_audio_buffer_append audio)
  in
  require_contains "append type" ~needle:"\"type\":\"input_audio_buffer.append\"" raw;
  require_contains "audio data" ~needle:"\"audio\":\"AAECAw==\"" raw

let test_realtime_decode_server_events () =
  (match
     O.Realtime.decode_server_event
       "{\"type\":\"response.output_audio.delta\",\"delta\":\"abc\"}"
   with
  | O.Realtime.Response_audio_delta "abc" -> ()
  | _ -> Alcotest.fail "expected audio delta");
  match
    O.Realtime.decode_server_event
      "{\"type\":\"error\",\"error\":{\"code\":\"bad_request\",\"message\":\"nope\"}}"
  with
  | O.Realtime.Server_error { code = Some "bad_request"; message = "nope"; _ } -> ()
  | _ -> Alcotest.fail "expected realtime error event"

(* P1: OpenAI codec raises Invalid_argument instead of returning typed error
   when tool result content contains image/video. *)

let test_openai_tool_result_with_image_does_not_crash () =
  let request : A.chat_request =
    {
      model = "gpt-4o-mini";
      prompt =
        [
          A.User [ A.Text "take screenshot" ];
          A.Tool
            {
              tool_call_id = "call_screenshot";
              content =
                [
                  A.Text "Screenshot:";
                  A.Image { url = "data:image/png;base64,iVBORw0KGgo="; detail = None };
                ];
            };
        ];
      tools = [];
      temperature = None;
      max_output_tokens = Some 100;
      replay_items = [];
      stream = false;
    }
  in
  (* encode_chat uses chat_message_json which calls chat_content_json for Tool.
     encode_responses uses input_items which calls contents_text for Tool.
     contents_text raises Invalid_argument on Image content. *)
  let crashed_responses =
    try
      ignore (O.encode_responses request);
      false
    with Invalid_argument _ -> true
  in
  let crashed_chat =
    try
      ignore (O.encode_chat request);
      false
    with Invalid_argument _ -> true
  in
  (* At least one encoder should NOT crash. Both crashing proves the bug. *)
  Alcotest.(check bool)
    "encode_responses should NOT throw Invalid_argument on image in tool result"
    false crashed_responses;
  Alcotest.(check bool)
    "encode_chat should NOT throw Invalid_argument on image in tool result"
    false crashed_chat

let tests =
  [
      ( "provider",
        [
          Alcotest.test_case "value" `Quick test_provider_value;
          Alcotest.test_case "encode chat and responses" `Quick
            test_encode_chat_and_responses;
          Alcotest.test_case "encodes audio content" `Quick
            test_chat_and_responses_encode_audio_content;
          Alcotest.test_case "tool result with image does not crash" `Quick
            test_openai_tool_result_with_image_does_not_crash;
          Alcotest.test_case "image content wire shape" `Quick
            test_openai_image_content_wire_shape;
        ] );
      ( "decode",
        [
          Alcotest.test_case "chat fixture" `Quick test_decode_chat_fixture;
          Alcotest.test_case "fractional usage integer rejected" `Quick
            test_decode_chat_rejects_fractional_usage_integer;
          Alcotest.test_case "chat usage details" `Quick
            test_decode_chat_usage_details;
          Alcotest.test_case "tool fixture" `Quick test_decode_tool_fixture;
          Alcotest.test_case "responses fixture" `Quick
            test_decode_responses_fixture;
          Alcotest.test_case "responses failed status is error" `Quick
            test_decode_responses_failed_status_is_error;
        ] );
      ( "streaming",
        [
          Alcotest.test_case "SSE fixture" `Quick test_stream_fixture;
          Alcotest.test_case "responses function call metadata" `Quick
            test_responses_stream_preserves_function_call_name;
          Alcotest.test_case "padded done sentinel" `Quick
            test_stream_done_allows_surrounding_whitespace;
          Alcotest.test_case "stream runner" `Quick test_stream_runner;
        ] );
      ( "http",
        [
          Alcotest.test_case "responses runner" `Quick
            test_responses_runner_uses_eta_http_and_suppresses_transport_span;
          Alcotest.test_case "provider error" `Quick
            test_responses_runner_provider_error;
          Alcotest.test_case "decode error categories" `Quick
            test_openai_decode_error_projects_categories;
          Alcotest.test_case "responses request" `Quick
            test_responses_request_uses_responses_endpoint;
          Alcotest.test_case "embeddings request and decode" `Quick
            test_embeddings_request_and_decode;
          Alcotest.test_case "image generation request and decode" `Quick
            test_image_generation_request_and_decode;
          Alcotest.test_case "speech runner" `Quick test_speech_runner;
          Alcotest.test_case "transcription request and decode" `Quick
            test_transcription_request_and_decode;
          Alcotest.test_case "transcription multipart validation" `Quick
            test_transcription_request_rejects_multipart_header_injection;
          Alcotest.test_case "transcription multipart boundary collision" `Quick
            test_transcription_request_avoids_boundary_collision;
        ] );
      ( "realtime",
        [
          Alcotest.test_case "session JSON" `Quick test_realtime_session_json;
          Alcotest.test_case "client secret request" `Quick
            test_realtime_client_secret_request;
          Alcotest.test_case "audio append event" `Quick
            test_realtime_client_event_audio_append;
          Alcotest.test_case "server event decode" `Quick
            test_realtime_decode_server_events;
        ] );
  ]
end
