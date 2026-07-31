module A = Eta_ai
module C = Eta_ai_openai_compat
module E = Eta.Effect
module H = Eta_http

let project err = A.project_ai_error (C.Error.to_ai_error err)

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct

let read_fixture = Eta_ai_test_support.read_fixture
let expect_ok = Eta_ai_test_support.expect_ok

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

let check_attr label expected attrs key =
  Alcotest.(check (option string)) label (Some expected)
    (List.assoc_opt key attrs)

let weather_schema =
  "{\"type\":\"object\",\"required\":[\"location\"],\"properties\":{\"location\":{\"type\":\"string\"}},\"additionalProperties\":false}"

let weather_tool () =
  A.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok "weather tool"

let chat_request ?reasoning ?(stream = false) ?(model = "mistral-large-latest") () :
    A.chat_request =
  {
    model;
    prompt = [ A.User [ A.Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    reasoning;
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

let test_client ?(with_http_span = false) response captured =
  let request http_request =
    captured := Some http_request;
    let eff = E.pure response in
    if with_http_span then
      Eta_observability.named ~kind:Eta.Capabilities.Client "HTTP POST" eff
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
  | H.Request.Stream _ | H.Request.One_shot_stream _
  | H.Request.Rewindable_stream _ ->
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
    (request_body_string request);
  match
    C.chat_completions_request ~provider ~api_key:(A.api_key "mk-test")
      (chat_request ~reasoning:"high" ())
  with
  | Stdlib.Error (C.Error.Unsupported _) -> ()
  | _ -> Alcotest.fail "expected unsupported reasoning error"

let test_decode_compatible_fixtures () =
  let text =
    C.decode_chat (read_fixture "together_chat.json")
    |> expect_ok "together chat"
  in
  Alcotest.(check string) "text" "Compatible response"
    (assistant_text text.message);
  Alcotest.(check (option int))
    "cache reporting unavailable" None
    (Option.bind text.usage (fun usage -> usage.A.input_tokens.cache_read));
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
      (C.Error.Decode
        {
          provider = "openai-compatible";
          message = "chat completion missing choices";
          raw_body = Some actual;
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
  let spans = Eta_observability.Tracer.dump tracer in
  Alcotest.(check bool)
    "transport span suppressed" false
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "HTTP POST")
       spans);
  Alcotest.(check bool)
    "chat span provider model" true
    (List.exists
       (fun (span : Eta_observability.Tracer.span) ->
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
      |> E.bind C.read_stream_events)
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
  let decode_error_hit = ref false in
  let provider =
    let base = mistral_provider () in
    {
      base with
      A.decode_error =
        (fun ~status:_ ~headers:_ _ ->
          decode_error_hit := true;
          A.Invalid_request { provider = "wrong"; message = "wrong decoder" });
    }
  in
  match
    B.run rt
      (C.chat_completions ~provider client ~api_key:(A.api_key "mk-test")
         (chat_request ()))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (C.Error.Provider
          {
            provider = "mistral";
            response =
              {
                status = 404;
                headers;
                payload = Some payload;
                raw_body;
              };
          } as error)) ->
      Alcotest.(check (option string)) "content-type" (Some "application/json")
        (H.Core.Header.get "content-type" headers);
      require_contains "aierr-iw3m payload" ~needle:"model_not_found"
        (A.Json.compact payload);
      require_contains "aierr-iw3m raw body" ~needle:"Invalid model" raw_body;
      (match C.Error.to_ai_error error with
      | A.Provider_error
          {
            provider = "mistral";
            status = Some 404;
            code = Some "model_not_found";
            message = "Invalid model";
            _;
          } ->
          ()
      | _ -> Alcotest.fail "expected total neutral projection");
      Alcotest.(check bool)
        "nominal runner owns non-success decoding" false !decode_error_hit;
      ignore (project error)
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<compat-error>"))
        cause

let test_aierr_compat_unknown_response () =
  match
    C.decode_error ~provider:"mistral" ~status:502
      ~headers:H.Core.Header.empty "<html>nope"
  with
  | C.Error.Unknown_response
      { provider = "mistral"; response = { status = 502; raw_body; _ } } ->
      Alcotest.(check string) "raw" "<html>nope" raw_body
  | _ -> Alcotest.fail "expected Unknown_response"

let test_aierr_compat_http_transport_failure () =
  with_runtime @@ fun rt ->
  let client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        E.fail
          (Eta_http.Error.make ~method_:"POST" ~uri:"https://example/v1/chat"
             (Eta_http.Error.Connect_error { message = "down" })))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let provider = mistral_provider () in
  match
    B.run rt
      (C.chat_completions ~provider client ~api_key:(A.api_key "k")
         (chat_request ()))
  with
  | Eta.Exit.Error (Eta.Cause.Fail (C.Error.Http _)) -> ()
  | _ -> Alcotest.fail "expected Http"

let test_aierr_compat_stream_open_and_midstream () =
  with_runtime @@ fun rt ->
  let provider = mistral_provider () in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let client =
    test_client (response_of_fixture ~status:404 ~headers "error.json") (ref None)
  in
  (match
     B.run rt
       (C.stream_chat_completions ~provider client ~api_key:(A.api_key "k")
          (chat_request ()))
   with
  | Eta.Exit.Error (Eta.Cause.Fail (C.Error.Provider { provider = "mistral"; _ }))
    ->
      ()
  | _ -> Alcotest.fail "stream-open must fail");
  let mid =
    "data: {\"error\":{\"message\":\"mid\",\"code\":\"x\"}}\n\n"
  in
  let stream_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client =
    test_client
      (H.Response.make ~status:200 ~headers:stream_headers
         ~body:(H.Body.Stream.of_bytes [ Bytes.of_string mid ])
         ())
      (ref None)
  in
  match
    B.run rt
      (C.stream_chat_completions ~provider client ~api_key:(A.api_key "k")
         (chat_request ())
      |> E.bind C.read_stream_events)
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (C.Error.Provider_response { provider = "mistral"; message = Some "mid"; _ }))
    ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "midstream must fail"
  | _ -> Alcotest.fail "unexpected midstream"

let test_aierr_compat_structured_output_honors_custom_encode () =
  let encode_hit = ref false in
  let base = mistral_provider () in
  let provider =
    {
      base with
      A.encode_chat =
        (fun req ->
          encode_hit := true;
          base.encode_chat req);
    }
  in
  let structured =
    C.structured_output ~name:"answer" ~schema_json:weather_schema ()
    |> function
    | Stdlib.Ok v -> v
    | Stdlib.Error _ -> Alcotest.fail "structured_output"
  in
  let request =
    C.chat_completions_request ~structured_output:structured ~provider
      ~api_key:(A.api_key "k") (chat_request ())
    |> function
    | Stdlib.Ok v -> v
    | Stdlib.Error _ -> Alcotest.fail "request"
  in
  Alcotest.(check bool) "custom encode" true !encode_hit;
  let body =
    match request.body with
    | H.Request.Fixed chunks ->
        Bytes.to_string (Bytes.concat Bytes.empty chunks)
    | _ -> Alcotest.fail "fixed body"
  in
  require_contains "response_format" ~needle:"response_format" body;
  require_contains "schema name" ~needle:"answer" body

let test_aierr_compat_invalid_request_roundtrip () =
  (match
    C.Error.of_ai_error ~provider:"mistral"
      (A.Invalid_request { provider = "mistral"; message = "local" })
  with
  | C.Error.Invalid_request { provider = "mistral"; message = "local" } -> ()
  | C.Error.Provider_response _ ->
      Alcotest.fail "must not reclassify Invalid_request"
  | _ -> Alcotest.fail "expected Invalid_request");
  let neutral_provider code =
    A.Provider_error
      {
        provider = "ignored";
        status = Some 422;
        code = Some code;
        message = "remote";
        raw = Some "{\"remote\":true}";
        retry_after_s = Some 99;
      }
  in
  let check code =
    match C.Error.of_ai_error ~provider:"mistral" (neutral_provider code) with
    | C.Error.Provider_response
        {
          provider = "mistral";
          status = Some 422;
          code = Some actual_code;
          message = Some "remote";
          raw_body = Some "{\"remote\":true}";
          payload = Some (`Assoc [ ("remote", `Bool true) ]);
        } -> Alcotest.(check string) "provider code" code actual_code
    | C.Error.Provider _ | C.Error.Unknown_response _ ->
        Alcotest.fail "of_ai_error must not invent an HTTP envelope or headers"
    | _ -> Alcotest.fail "expected lossless Provider_response"
  in
  check "remote_code";
  check "invalid_request"

let test_aierr_compat_validation_and_configured_identity () =
  let bad = { (chat_request ()) with temperature = Some nan } in
  (match C.encode_chat ~provider:"mistral" bad with
  | Stdlib.Error
      (C.Error.Invalid_request { provider = "mistral"; message = _ }) ->
      ()
  | _ -> Alcotest.fail "direct compat validation must be Invalid_request");
  let base = mistral_provider () in
  (match C.Chat.encode ~provider:base bad with
  | Stdlib.Error (C.Error.Invalid_request { provider = "mistral"; _ }) -> ()
  | _ -> Alcotest.fail "callback roundtrip must retain Invalid_request");
  (match
     C.chat_completions_request ~provider:base ~api_key:(A.api_key "k") bad
   with
  | Stdlib.Error (C.Error.Invalid_request { provider = "mistral"; _ }) -> ()
  | _ -> Alcotest.fail "builder must retain Invalid_request");
  with_runtime @@ fun rt ->
  let requests = ref 0 in
  let client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        incr requests;
        E.pure (response_of_fixture "together_chat.json"))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  (match
     B.run rt
       (C.chat_completions ~provider:base client ~api_key:(A.api_key "k") bad)
   with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (C.Error.Invalid_request { provider = "mistral"; _ })) ->
      ()
  | _ -> Alcotest.fail "runner must retain Invalid_request");
  Alcotest.(check int) "invalid request never reaches transport" 0 !requests;
  let wrong_identity =
    {
      base with
      A.encode_chat =
        (fun _ ->
          Stdlib.Error
            (A.Decode_error
               { provider = "wrong"; message = "callback"; raw = None }));
    }
  in
  (match C.Chat.encode ~provider:wrong_identity (chat_request ()) with
  | Stdlib.Error
      (C.Error.Decode { provider = "mistral"; message = "callback"; _ }) ->
      ()
  | _ -> Alcotest.fail "configured identity must override callback attribution");
  let embedding_encode = ref false in
  let embedding_decode = ref false in
  let embedding_provider =
    {
      base with
      A.encode_embeddings =
        (fun _ -> embedding_encode := true; Stdlib.Ok "{\"embedding\":true}");
      decode_embeddings =
        (fun _ ->
          embedding_decode := true;
          Stdlib.Ok
            {
              A.Embedding.id = Some "callback";
              model = Some "callback-model";
              embeddings = [];
              usage = None;
              raw = None;
            });
    }
  in
  ignore
    (C.Embeddings.encode ~provider:embedding_provider
       {
         A.Embedding.model = "m";
         input = A.Embedding.Text "x";
         encoding_format = None;
         dimensions = None;
         user = None;
       }
    |> expect_ok "compat embedding callback encode");
  let decoded =
    C.Embeddings.decode ~provider:embedding_provider "{}"
    |> expect_ok "compat embedding callback decode"
  in
  Alcotest.(check bool) "embedding encode callback" true !embedding_encode;
  Alcotest.(check bool) "embedding decode callback" true !embedding_decode;
  Alcotest.(check (option string)) "embedding decode sentinel" (Some "callback")
    decoded.id

let test_aierr_compat_structured_output_injection_failures () =
  let structured =
    C.structured_output ~name:"answer" ~schema_json:weather_schema ()
    |> expect_ok "structured"
  in
  let base = mistral_provider () in
  let check encoded expected =
    let provider = { base with A.encode_chat = (fun _ -> Stdlib.Ok encoded) } in
    match
      C.chat_completions_request ~structured_output:structured ~provider
        ~api_key:(A.api_key "k") (chat_request ())
    with
    | Stdlib.Error error -> expected error
    | Stdlib.Ok _ -> Alcotest.fail "invalid callback JSON unexpectedly accepted"
  in
  check "{bad" (function
    | C.Error.Decode { provider = "mistral"; raw_body = Some "{bad"; _ } -> ()
    | _ -> Alcotest.fail "malformed callback JSON must be configured Decode");
  check "[]" (function
    | C.Error.Invalid_request { provider = "mistral"; _ } -> ()
    | _ -> Alcotest.fail "non-object callback JSON must be configured Invalid_request");
  let provider =
    {
      base with
      A.encode_chat =
        (fun _ ->
          Stdlib.Ok
            "{\"sentinel\":true,\"response_format\":{\"old\":true}}");
    }
  in
  let request =
    C.chat_completions_request ~structured_output:structured ~provider
      ~api_key:(A.api_key "k") (chat_request ())
    |> expect_ok "injected request"
  in
  let body = request_body_string request in
  require_contains "unrelated callback field retained" ~needle:"\"sentinel\":true" body;
  require_contains "old response format replaced" ~needle:"\"name\":\"answer\"" body;
  Alcotest.(check bool) "old response format removed" false
    (contains ~needle:"\"old\":true" body)

let test_aierr_compat_projection_matrix () =
  let http =
    Eta_http.Error.make ~method_:"POST" ~uri:"https://mistral.test/v1"
      (Eta_http.Error.Connect_error { message = "down" })
  in
  (match C.Error.to_ai_error (C.Error.Http http) with
  | A.Eta_http_error projected ->
      Alcotest.(check string) "Http identity" (Eta_http.Error.to_string http)
        (Eta_http.Error.to_string projected)
  | _ -> Alcotest.fail "Http projection");
  let headers = H.Core.Header.unsafe_of_list [ ("retry-after", "5") ] in
  (match
     C.Error.to_ai_error
       (C.Error.Provider
          {
            provider = "mistral";
            response =
              {
                status = 429;
                headers;
                payload = Some (`Assoc [ ("message", `String "slow") ]);
                raw_body = "{\"message\":\"slow\"}";
              };
          })
   with
  | A.Provider_error
      {
        provider = "mistral";
        status = Some 429;
        code = None;
        message = "slow";
        raw = Some "{\"message\":\"slow\"}";
        retry_after_s = Some 5;
      } -> ()
  | _ -> Alcotest.fail "Provider projection facts");
  (match
     C.Error.to_ai_error
       (C.Error.Unknown_response
          {
            provider = "mistral";
            response = { status = 502; headers; payload = None; raw_body = "bad" };
          })
   with
  | A.Provider_error
      { provider = "mistral"; status = Some 502; raw = Some "bad"; retry_after_s = Some 5; _ } ->
      ()
  | _ -> Alcotest.fail "Unknown_response projection");
  (match
     C.Error.to_ai_error
       (C.Error.Provider_response
          {
            provider = "mistral";
            status = Some 400;
            payload = None;
            raw_body = Some "raw";
            message = Some "provider";
            code = Some "c";
          })
   with
  | A.Provider_error
      {
        provider = "mistral";
        status = Some 400;
        code = Some "c";
        message = "provider";
        raw = Some "raw";
        retry_after_s = None;
      } -> ()
  | _ -> Alcotest.fail "Provider_response projection facts");
  (match
     C.Error.to_ai_error
       (C.Error.Decode
          { provider = "mistral"; message = "decode"; raw_body = Some "raw" })
   with
  | A.Decode_error { provider = "mistral"; message = "decode"; raw = Some "raw" } -> ()
  | _ -> Alcotest.fail "Decode projection");
  (match
     C.Error.to_ai_error
       (C.Error.Invalid_request { provider = "mistral"; message = "bad" })
   with
  | A.Invalid_request { provider = "mistral"; message = "bad" } -> ()
  | _ -> Alcotest.fail "Invalid_request projection");
  (match
     C.Error.to_ai_error
       (C.Error.Unsupported { provider = "mistral"; feature = "video" })
   with
  | A.Unsupported { provider = "mistral"; feature = "video" } -> ()
  | _ -> Alcotest.fail "Unsupported projection");
  match
    C.Error.to_ai_error (C.Error.Invalid_tool { name = "tool"; message = "bad" })
  with
  | A.Invalid_tool { name = "tool"; message = "bad" } -> ()
  | _ -> Alcotest.fail "Invalid_tool projection"

let test_aierr_compat_stream_callbacks_and_identity () =
  with_runtime @@ fun rt ->
  let base = mistral_provider () in
  let headers = H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ] in
  let run ?(release_effect = fun () -> E.unit) ?(plural = false) provider release =
    let first = ref true in
    let body =
      H.Body.Stream.of_reader
        ~release:(fun () -> incr release; release_effect ())
        (fun () ->
          if !first then (
            first := false;
            E.pure (H.Body.Stream.Chunk (Bytes.of_string "data: {}\n\n")))
          else E.pure H.Body.Stream.End)
    in
    let client =
      test_client (H.Response.make ~status:200 ~headers ~body ()) (ref None)
    in
    let read stream =
      if plural then C.read_stream_events stream |> E.map ignore
      else C.read_stream_event stream |> E.map ignore
    in
    B.run rt
      (C.stream_chat_completions ~provider client ~api_key:(A.api_key "k")
         (chat_request ())
      |> E.bind read)
  in
  let outer_release = ref 0 in
  let outer =
    {
      base with
      A.decode_stream_event =
        (fun _ ->
          Stdlib.Error
            (A.Decode_error
               { provider = "wrong"; message = "outer"; raw = Some "{}" }));
    }
  in
  (match run outer outer_release with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (C.Error.Decode
          { provider = "mistral"; message = "outer"; raw_body = Some "{}" })) ->
      ()
  | _ -> Alcotest.fail "outer callback error must retain configured identity");
  Alcotest.(check int) "outer release exactly once" 1 !outer_release;
  let rec outer_primary_preserved = function
    | Eta.Cause.Fail
        (C.Error.Decode
          { provider = "mistral"; message = "outer"; raw_body = Some "{}" }) ->
        true
    | Eta.Cause.Suppressed { primary; _ } -> outer_primary_preserved primary
    | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
        List.exists outer_primary_preserved causes
    | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _
    | Eta.Cause.Finalizer _ -> false
  in
  let check_outer_cleanup label ~plural release_effect =
    let releases = ref 0 in
    match run ~release_effect ~plural outer releases with
    | Eta.Exit.Error cause ->
        Alcotest.(check bool) (label ^ " primary") true
          (outer_primary_preserved cause);
        Alcotest.(check int) (label ^ " release exactly once") 1 !releases
    | Eta.Exit.Ok _ -> Alcotest.fail (label ^ " unexpectedly succeeded")
  in
  check_outer_cleanup "outer typed cleanup" ~plural:false (fun () ->
      E.fail
        (Eta_http.Error.make ~method_:"GET" ~uri:"stream"
           (Eta_http.Error.Connect_error { message = "cleanup-typed" })));
  check_outer_cleanup "outer defect cleanup plural" ~plural:true (fun () ->
      E.die_message "cleanup-defect");
  let plural_release = ref 0 in
  let quiet = { base with A.decode_stream_event = (fun _ -> Stdlib.Ok []) } in
  (match run ~plural:true quiet plural_release with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error _ -> Alcotest.fail "plural successful cleanup failed");
  Alcotest.(check int) "plural successful release exactly once" 1 !plural_release;
  let embedded_release = ref 0 in
  let embedded =
    {
      base with
      A.decode_stream_event =
        (fun _ ->
          Stdlib.Ok
            [
              A.Stream_error
                (A.Provider_error
                   {
                     provider = "wrong";
                     status = None;
                     code = Some "mid";
                     message = "embedded";
                     raw = Some "{}";
                     retry_after_s = None;
                   });
            ]);
    }
  in
  (match run embedded embedded_release with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (C.Error.Provider_response
          { provider = "mistral"; message = Some "embedded"; _ })) ->
      Alcotest.(check int) "embedded release exactly once" 1 !embedded_release
  | _ -> Alcotest.fail "embedded callback error must retain configured identity");
  let rec primary_preserved = function
    | Eta.Cause.Fail
        (C.Error.Provider_response
          { provider = "mistral"; message = Some "embedded"; _ }) ->
        true
    | Eta.Cause.Suppressed { primary; _ } -> primary_preserved primary
    | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
        List.exists primary_preserved causes
    | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _
    | Eta.Cause.Finalizer _ ->
        false
  in
  let cleanup_release = ref 0 in
  match
    run
      ~release_effect:(fun () ->
        E.fail
          (Eta_http.Error.make ~method_:"GET" ~uri:"stream"
             (Eta_http.Error.Connect_error { message = "cleanup" })))
      embedded cleanup_release
  with
  | Eta.Exit.Error cause ->
      Alcotest.(check bool) "cleanup preserves provider primary" true
        (primary_preserved cause);
      Alcotest.(check int) "failing cleanup release exactly once" 1
        !cleanup_release
  | Eta.Exit.Ok _ -> Alcotest.fail "failing cleanup unexpectedly succeeded"

let test_aierr_compat_telemetry_exact () =
  with_traced_runtime @@ fun rt tracer ->
  let provider = mistral_provider () in
  let success =
    test_client ~with_http_span:true
      (response_of_fixture "together_chat.json") (ref None)
  in
  ignore
    (run_ok rt "compat telemetry"
       (C.chat_completions ~provider success ~api_key:(A.api_key "k")
          (chat_request ~model:"meta-llama/Llama-3.3-70B-Instruct-Turbo" ())));
  let span =
    Eta.Tracer.dump tracer
    |> List.find (fun (span : Eta.Tracer.span) ->
           String.equal span.name
             "chat meta-llama/Llama-3.3-70B-Instruct-Turbo")
  in
  let attrs = span.attrs in
  check_attr "operation" "chat" attrs "gen_ai.operation.name";
  check_attr "provider" "mistral" attrs "gen_ai.provider.name";
  check_attr "request model" "meta-llama/Llama-3.3-70B-Instruct-Turbo" attrs
    "gen_ai.request.model";
  check_attr "server address" "api.mistral.ai" attrs "server.address";
  check_attr "server port" "443" attrs "server.port";
  check_attr "response id" "chatcmpl_together_fixture" attrs
    "gen_ai.response.id";
  check_attr "response model" "meta-llama/Llama-3.3-70B-Instruct-Turbo" attrs
    "gen_ai.response.model";
  check_attr "finish" "stop" attrs "gen_ai.response.finish_reasons";
  check_attr "input usage" "8" attrs "gen_ai.usage.input_tokens";
  check_attr "output usage" "3" attrs "gen_ai.usage.output_tokens";
  let stream_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let stream_client =
    test_client (response_of_fixture ~headers:stream_headers "stream.sse")
      (ref None)
  in
  ignore
    (run_ok rt "compat telemetry stream"
       (C.stream_chat_completions ~provider stream_client
          ~api_key:(A.api_key "k") (chat_request ())
       |> E.bind C.read_stream_events));
  let stream_span =
    Eta.Tracer.dump tracer
    |> List.find (fun (span : Eta.Tracer.span) ->
           List.assoc_opt "gen_ai.request.stream" span.attrs = Some "true")
  in
  check_attr "stream flag" "true" stream_span.attrs "gen_ai.request.stream";
  let error_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let error_client =
    test_client (response_of_fixture ~status:404 ~headers:error_headers "error.json")
      (ref None)
  in
  ignore
    (B.run rt
       (C.chat_completions ~provider error_client ~api_key:(A.api_key "k")
          (chat_request ())));
  let error_span =
    Eta.Tracer.dump tracer
    |> List.find (fun (span : Eta.Tracer.span) ->
           List.assoc_opt "error.type" span.attrs = Some "model_not_found")
  in
  check_attr "error type" "model_not_found" error_span.attrs "error.type";
  Alcotest.(check bool) "nested transport suppressed" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
       (Eta.Tracer.dump tracer))

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
          Alcotest.test_case "aierr compat unknown response" `Quick
            test_aierr_compat_unknown_response;
          Alcotest.test_case "aierr compat http transport" `Quick
            test_aierr_compat_http_transport_failure;
          Alcotest.test_case "aierr compat stream open midstream" `Quick
            test_aierr_compat_stream_open_and_midstream;
          Alcotest.test_case "aierr compat structured_output custom encode" `Quick
            test_aierr_compat_structured_output_honors_custom_encode;
          Alcotest.test_case "aierr compat invalid_request roundtrip" `Quick
            test_aierr_compat_invalid_request_roundtrip;
          Alcotest.test_case "aierr compat validation configured identity" `Quick
            test_aierr_compat_validation_and_configured_identity;
          Alcotest.test_case "aierr compat structured_output injection failures" `Quick
            test_aierr_compat_structured_output_injection_failures;
          Alcotest.test_case "aierr compat projection matrix" `Quick
            test_aierr_compat_projection_matrix;
          Alcotest.test_case "aierr compat stream callbacks identity" `Quick
            test_aierr_compat_stream_callbacks_and_identity;
          Alcotest.test_case "aierr compat telemetry exact" `Quick
            test_aierr_compat_telemetry_exact;
          Alcotest.test_case "runner suppression" `Quick
            test_runner_suppresses_transport_span;
          Alcotest.test_case "stream runner" `Quick test_stream_runner;
          Alcotest.test_case "provider error" `Quick test_provider_error;
        ] );
  ]
end
