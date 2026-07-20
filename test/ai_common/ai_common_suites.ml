open Eta_ai

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct

let test_message_vocabulary () =
  let call =
    {
      id = "call_weather";
      name = "weather";
      arguments_json = "{\"location\":\"SF\"}";
    }
  in
  let message =
    Assistant { content = [ Text "checking" ]; tool_calls = [ call ] }
  in
  match message with
  | Assistant { content = [ Text "checking" ]; tool_calls = [ actual ] } ->
      Alcotest.(check string) "tool call id" "call_weather" actual.id;
      Alcotest.(check string) "tool call name" "weather" actual.name
  | _ -> Alcotest.fail "expected assistant tool call message"

let test_tool_schema_stays_raw_json () =
  let tool =
    {
      name = "weather";
      description = Some "Get current weather";
      input_schema_json =
        "{\"type\":\"object\",\"required\":[\"location\"],\"properties\":{\"location\":{\"type\":\"string\"}}}";
      strict = Some true;
    }
  in
  Alcotest.(check string) "tool name" "weather" tool.name;
  Alcotest.(check bool) "raw schema preserved" true
    (String.contains tool.input_schema_json '{')

let test_audio_content_variant () =
  match audio_pcm16_base64 ~transcript:"hello" "AAECAw==" with
  | Audio { data = Base64 data; format = Pcm16; transcript = Some transcript } ->
      Alcotest.(check string) "data" "AAECAw==" data;
      Alcotest.(check string) "transcript" "hello" transcript
  | _ -> Alcotest.fail "expected pcm16 base64 audio content"

let test_provider_error_preserves_raw_body () =
  let error =
    Provider_error
      {
        provider = "openrouter";
        status = Some 502;
        code = Some "server_error";
        message = "Provider disconnected";
        raw = Some "{\"error\":{\"message\":\"Provider disconnected\"}}";
        retry_after_s = None;
      }
  in
  match error with
  | Provider_error { provider; status; raw = Some raw; _ } ->
      Alcotest.(check string) "provider" "openrouter" provider;
      Alcotest.(check (option int)) "status" (Some 502) status;
      Alcotest.(check bool) "raw json" true (String.contains raw '{')
  | _ -> Alcotest.fail "expected provider error"

let check_projection label ~category ~status ~retryable ~retry_after_s error =
  let actual = project_ai_error error in
  Alcotest.(check string)
    (label ^ " category")
    (ai_error_category_to_string category)
    (ai_error_category_to_string actual.category);
  Alcotest.(check (option int)) (label ^ " status") status actual.status;
  Alcotest.(check bool) (label ^ " retryable") retryable actual.retryable;
  Alcotest.(check (option int))
    (label ^ " retry_after_s") retry_after_s actual.retry_after_s;
  actual

let make_provider_error ?status ?code ?retry_after_s ?(raw = None) ~provider
    message =
  Provider_error
    {
      provider;
      status;
      code;
      message;
      raw;
      retry_after_s;
    }

let test_project_ai_error_status_and_code_categories () =
  ignore
    (check_projection "429 rate limit" ~category:Transient ~status:(Some 429)
       ~retryable:true ~retry_after_s:None
       (make_provider_error ~provider:"openai" ~status:429
          ~code:"rate_limit_exceeded" "Rate limit reached"));
  ignore
    (check_projection "500 server" ~category:Transient ~status:(Some 500)
       ~retryable:true ~retry_after_s:None
       (make_provider_error ~provider:"openai" ~status:500 ~code:"server_error"
          "internal"));
  ignore
    (check_projection "402 billing status" ~category:Billing ~status:(Some 402)
       ~retryable:false ~retry_after_s:None
       (make_provider_error ~provider:"openrouter" ~status:402
          "Payment required"))

let test_project_ai_error_nonretryable_quota_billing_context () =
  ignore
    (check_projection "quota code" ~category:Quota_budget ~status:(Some 429)
       ~retryable:false ~retry_after_s:None
       (make_provider_error ~provider:"openai" ~status:429
          ~code:"insufficient_quota" "You exceeded your current quota"));
  ignore
    (check_projection "billing code" ~category:Billing ~status:(Some 400)
       ~retryable:false ~retry_after_s:None
       (make_provider_error ~provider:"openai" ~status:400
          ~code:"billing_not_active" "Billing not active"));
  ignore
    (check_projection "context overflow code" ~category:Context_overflow
       ~status:(Some 400) ~retryable:false ~retry_after_s:None
       (make_provider_error ~provider:"openai" ~status:400
          ~code:"context_length_exceeded"
          "This model's maximum context length is 128000 tokens"));
  ignore
    (check_projection "message-only context fallback" ~category:Context_overflow
       ~status:(Some 400) ~retryable:false ~retry_after_s:None
       (make_provider_error ~provider:"openai" ~status:400
          "prompt is too long for the model context window"))

let test_project_ai_error_retry_after_and_transport () =
  ignore
    (check_projection "provider retry after" ~category:Transient
       ~status:(Some 429) ~retryable:true ~retry_after_s:(Some 12)
       (make_provider_error ~provider:"openai" ~status:429
          ~code:"rate_limit_exceeded" ~retry_after_s:12 "slow down"));
  let transport =
    Eta_http.Error.make ~method_:"POST" ~uri:"https://api.example/v1"
      (Eta_http.Error.Connect_timeout { timeout_ms = Some 250 })
  in
  let failure =
    check_projection "transport" ~category:Transient ~status:None
      ~retryable:true ~retry_after_s:None (Eta_http_error transport)
  in
  Alcotest.(check bool) "transport diagnostic kind" true
    (String.starts_with ~prefix:"kind=http_error" failure.diagnostic)

let test_project_ai_error_diagnostic_redaction_and_bounding () =
  let secret_body =
    "{\"error\":{\"message\":\"secret body\",\"authorization\":\"Bearer sk-live\"}}"
  in
  let long_message = String.make 400 'x' in
  let failure =
    project_ai_error
      (make_provider_error ~provider:"openai" ~status:500 ~code:"server_error"
         ~raw:(Some secret_body) long_message)
  in
  Alcotest.(check bool) "raw body omitted" false
    (Eta.String_helpers.contains_ascii_ci failure.diagnostic secret_body);
  Alcotest.(check bool) "auth secret omitted" false
    (Eta.String_helpers.contains_ascii_ci failure.diagnostic "sk-live");
  Alcotest.(check bool) "authorization omitted" false
    (Eta.String_helpers.contains_ascii_ci failure.diagnostic "authorization");
  Alcotest.(check bool) "message bounded" true
    (String.length failure.diagnostic < 400);
  Alcotest.(check bool) "message truncated marker" true
    (Eta.String_helpers.contains_ascii_ci failure.diagnostic "...");
  Alcotest.(check bool) "structured fields present" true
    (Eta.String_helpers.contains_ascii_ci failure.diagnostic
       "kind=provider_error"
    && Eta.String_helpers.contains_ascii_ci failure.diagnostic "status=500"
    && Eta.String_helpers.contains_ascii_ci failure.diagnostic
         "code=server_error");
  Alcotest.(check (option int))
    "header retry after" (Some 7)
    (retry_after_from_headers
       (Eta_http.Core.Header.unsafe_of_list
          [ ("RETRY-AFTER", "7"); ("Authorization", "Bearer sk-live") ]))

let test_api_key_prints_redacted () =
  let key = api_key "sk-live-secret" in
  let rendered = Format.asprintf "%a" Eta_redacted.pp key in
  Alcotest.(check string) "labelled redaction" "<redacted:api_key>" rendered;
  Alcotest.(check bool) "secret omitted" false
    (String.equal rendered "sk-live-secret")

let base_usage =
  {
    input_tokens =
      { uncached = Some 3; total = Some 3; cache_read = None; cache_write = None };
    output_tokens = { total = Some 5; text = Some 5; reasoning = None };
    raw = [ ("provider", "fixture") ];
  }

let test_provider_value_carries_endpoint_auth_and_codecs () =
  let provider =
    {
      name = "openai";
      base_url = "https://api.openai.test";
      chat_path = "/v1/chat/completions";
      embeddings_path = Some "/v1/embeddings";
      auth_headers =
        (fun api_key ->
          Eta_http.Core.Header.unsafe_of_list
            [
              ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
              ("Content-Type", "application/json");
            ]);
      capabilities =
        {
          streaming = true;
          tools = true;
          tool_choice = true;
          structured_outputs = false;
          text = true;
          image_input = false;
          audio_input = false;
          video_input = false;
          embeddings = true;
          image_generation = false;
          speech = false;
          transcription = false;
          rerank = false;
          video_generation = false;
        };
      encode_chat =
        (fun request ->
          Ok
            (Eta_ai.Json.to_string
               (Eta_ai.Json.object_
                  [
                    ("model", Some (Eta_ai.Json.string request.model));
                    ("stream", Some (Eta_ai.Json.bool request.stream));
                    ( "message_count",
                      Some (Eta_ai.Json.int (List.length request.prompt)) );
                  ])));
      decode_chat =
        (fun raw ->
          Ok
            {
              id = Some "chatcmpl_fixture";
              model = Some "gpt-fixture";
              message = Assistant { content = [ Text "done" ]; tool_calls = [] };
              finish_reasons = [ Stop ];
              usage = Some base_usage;
              replay_items = [];
              raw = Some raw;
            });
      encode_embeddings =
        (fun request ->
          Ok
            (Eta_ai.Json.to_string
               (Eta_ai.Json.object_
                  [
                    ("model", Some (Eta_ai.Json.string request.model));
                    ("input", Some (Eta_ai.Json.string "fixture"));
                  ])));
      decode_embeddings =
        (fun raw ->
          Ok
            {
              id = Some "emb_fixture";
              model = Some "gpt-fixture";
              embeddings =
                [
                  {
                    embedding = Embedding.Float [ 0.1; 0.2 ];
                    index = Some 0;
                  };
                ];
              usage =
                Some
                  {
                    input_tokens = Some 2;
                    total_tokens = Some 2;
                    raw = [ ("provider", "fixture") ];
                  };
              raw = Some raw;
            });
      decode_stream_event =
        (fun event ->
          match event.data with
          | "[DONE]" -> Ok [ Stream_done ]
          | data -> Ok [ Stream_content_delta data ]);
      decode_error =
        (fun ~status ~headers:_ raw ->
          Provider_error
            {
              provider = "openai";
              status = Some status;
              code = Some "provider_error";
              message = "provider rejected request";
              raw = Some raw;
              retry_after_s = None;
            });
    }
  in
  let headers = provider.auth_headers (Eta_redacted.make "sk-test") in
  Alcotest.(check string) "provider name" "openai" provider.name;
  Alcotest.(check string)
    "authorization" "Bearer sk-test"
    (Option.get (Eta_http.Core.Header.get "authorization" headers));
  Alcotest.(check bool) "streams" true provider.capabilities.streaming;
  let request =
    {
      model = "gpt-fixture";
      prompt = [ User [ Text "hello" ] ];
      tools = [];
      temperature = Some 0.2;
      reasoning = None;
      max_output_tokens = Some 64;
      replay_items = [];
      stream = true;
    }
  in
  (match provider.encode_chat request with
  | Ok raw ->
      Alcotest.(check bool) "encoded model" true (String.contains raw 'g');
      (match provider.decode_chat raw with
      | Ok response ->
          Alcotest.(check (option string)) "response id"
            (Some "chatcmpl_fixture") response.id;
          Alcotest.(check (option int)) "input tokens" (Some 3)
            (Option.bind response.usage (fun usage -> usage.input_tokens.total))
      | Error _ -> Alcotest.fail "expected decoded response")
  | Error _ -> Alcotest.fail "expected encoded request");
  (match provider.decode_stream_event { event = None; data = "[DONE]" } with
  | Ok [ Stream_done ] -> ()
  | _ -> Alcotest.fail "expected stream done");
  match provider.decode_error ~status:401 ~headers:[] "{\"error\":true}" with
  | Provider_error { provider; status; raw = Some raw; _ } ->
      Alcotest.(check string) "error provider" "openai" provider;
      Alcotest.(check (option int)) "error status" (Some 401) status;
      Alcotest.(check bool) "error raw" true (String.contains raw '{')
  | _ -> Alcotest.fail "expected provider error"

let test_provider_encoder_can_reject_unsupported_features () =
  let provider =
    {
      name = "minimal";
      base_url = "https://minimal.example";
      chat_path = "/chat";
      embeddings_path = None;
      auth_headers = (fun _ -> []);
      capabilities =
        {
          streaming = false;
          tools = false;
          tool_choice = false;
          structured_outputs = false;
          text = true;
          image_input = false;
          audio_input = false;
          video_input = false;
          embeddings = false;
          image_generation = false;
          speech = false;
          transcription = false;
          rerank = false;
          video_generation = false;
        };
      encode_chat =
        (fun request ->
          match request.tools with
          | [] -> Ok "{}"
          | _ -> Error (Unsupported { provider = "minimal"; feature = "tools" }));
      decode_chat =
        (fun _ ->
          Ok
            {
              id = None;
              model = None;
              message = Assistant { content = []; tool_calls = [] };
              finish_reasons = [];
              usage = None;
              replay_items = [];
              raw = None;
            });
      encode_embeddings =
        (fun _ ->
          Error (Unsupported { provider = "minimal"; feature = "embeddings" }));
      decode_embeddings =
        (fun _ ->
          Error (Unsupported { provider = "minimal"; feature = "embeddings" }));
      decode_stream_event = (fun _ -> Ok []);
      decode_error =
        (fun ~status ~headers:_ raw ->
          Provider_error
            {
              provider = "minimal";
              status = Some status;
              code = None;
              message = "error";
              raw = Some raw;
              retry_after_s = None;
            });
    }
  in
  let request =
    {
      model = "minimal-model";
      prompt = [ User [ Text "hello" ] ];
      tools =
        [
          {
            name = "weather";
            description = None;
            input_schema_json = "{\"type\":\"object\"}";
            strict = None;
          };
        ];
      temperature = None;
      reasoning = None;
      max_output_tokens = None;
      replay_items = [];
      stream = false;
    }
  in
  match provider.encode_chat request with
  | Error (Unsupported { provider = "minimal"; feature = "tools" }) -> ()
  | _ -> Alcotest.fail "expected unsupported tools"

let test_provider_stream_decoder_handles_named_tool_delta () =
  let decode_stream_event event =
    match (event.event, event.data) with
    | Some "content_block_delta", data when String.contains data '{' ->
        Ok
          [
            Stream_tool_call_delta
              {
                index = Some 0;
                id = Some "toolu_fixture";
                name = Some "weather";
                arguments_json_delta = data;
              };
          ]
    | _ -> Ok []
  in
  match
    decode_stream_event
      {
        event = Some "content_block_delta";
        data = "{\"partial_json\":\"{\\\"location\"}";
      }
  with
  | Ok
      [
        Stream_tool_call_delta
          { id = Some "toolu_fixture"; name = Some "weather"; _ };
      ] ->
      ()
  | _ -> Alcotest.fail "expected tool-call delta"

let expect_ok label = function
  | Stdlib.Ok value -> value
  | Stdlib.Error _ -> Alcotest.fail ("expected Ok: " ^ label)

let weather_tool () =
  make_tool ~name:"weather" ~description:"Get weather"
    ~input_schema_json:
      "{\"type\":\"object\",\"required\":[\"location\"],\"properties\":{\"location\":{\"type\":\"string\"}},\"additionalProperties\":false}"
    ~strict:true ()
  |> expect_ok "weather tool"

let stock_tool () =
  make_tool ~name:"stock_price"
    ~input_schema_json:
      "{\"type\":\"object\",\"required\":[\"symbol\"],\"properties\":{\"symbol\":{\"type\":\"string\"}}}"
    ()
  |> expect_ok "stock tool"

let test_toolkit_registers_tools_in_order () =
  let toolkit =
    empty_toolkit |> add_tool (weather_tool ()) |> expect_ok "add weather"
    |> add_tool (stock_tool ()) |> expect_ok "add stock"
  in
  let names =
    List.map (fun (tool : Eta_ai.tool) -> tool.name) (toolkit_tools toolkit)
  in
  Alcotest.(check (list string))
    "tool order" [ "weather"; "stock_price" ] names;
  (match find_tool "weather" toolkit with
  | Some tool ->
      Alcotest.(check (option string)) "description"
        (Some "Get weather") tool.description
  | None -> Alcotest.fail "expected registered weather tool");
  match find_tool " weather " toolkit with
  | Some tool -> Alcotest.(check string) "normalized lookup" "weather" tool.name
  | None -> Alcotest.fail "expected normalized weather lookup"

let test_toolkit_rejects_duplicate_names () =
  let weather = weather_tool () in
  let spaced_weather =
    make_tool ~name:" weather "
      ~input_schema_json:weather.input_schema_json ()
    |> expect_ok "spaced weather"
  in
  let toolkit =
    empty_toolkit |> add_tool weather |> expect_ok "add weather"
  in
  (match add_tool weather toolkit with
  | Error
      (Invalid_tool
        { name = "weather"; message = "tool name already registered" }) ->
      ()
  | _ -> Alcotest.fail "expected duplicate tool rejection");
  Alcotest.(check string) "trimmed name" "weather" spaced_weather.name;
  match add_tool spaced_weather toolkit with
  | Error
      (Invalid_tool
        { name = "weather"; message = "tool name already registered" }) ->
      ()
  | _ -> Alcotest.fail "expected spaced duplicate tool rejection"

let test_toolkit_rejects_missing_schema () =
  match make_tool ~name:"bad" ~input_schema_json:" \t\n\r" () with
  | Error
      (Invalid_tool
        { name = "bad"; message = "input_schema_json is required" }) ->
      ()
  | _ -> Alcotest.fail "expected missing schema rejection"

let test_make_toolkit_preserves_raw_schema () =
  let tool = weather_tool () in
  let toolkit = make_toolkit [ tool ] |> expect_ok "make toolkit" in
  match find_tool "weather" toolkit with
  | Some actual ->
      Alcotest.(check string) "raw schema preserved" tool.input_schema_json
        actual.input_schema_json
  | None -> Alcotest.fail "expected tool"

let with_runtime f = B.with_runtime (fun _ctx rt -> f rt)

let with_traced_runtime f =
  B.with_traced_runtime (fun _ctx rt tracer -> f rt tracer)

let with_observed_runtime f =
  B.with_observed_runtime (fun _ctx rt tracer logger _meter ->
      f rt tracer logger)

let run_ok rt label eff =
  match B.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s failed: %s" label
        (Format.asprintf "%a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
           cause)

let expect_decode_error rt label eff =
  match B.run rt eff with
  | Eta.Exit.Error
      (Eta.Cause.Fail (Decode_error { provider; message; raw })) ->
      (provider, message, raw)
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s failed with unexpected cause: %s" label
        (Format.asprintf "%a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
           cause)
  | Eta.Exit.Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix

let drop_prefix ~prefix value =
  String.sub value (String.length prefix)
    (String.length value - String.length prefix)

let chunk_string value =
  let sizes = [| 1; 5; 2; 13; 3 |] in
  let rec loop index size_index acc =
    if index >= String.length value then List.rev acc
    else
      let size = sizes.(size_index mod Array.length sizes) in
      let len = min size (String.length value - index) in
      let chunk = Bytes.of_string (String.sub value index len) in
      loop (index + len) (size_index + 1) (chunk :: acc)
  in
  loop 0 0 []

let body_of_string ?release value =
  match release with
  | Some release -> Eta_http.Body.Stream.of_bytes ~release (chunk_string value)
  | None -> Eta_http.Body.Stream.of_bytes (chunk_string value)

let stream_provider =
  {
    name = "stream-fixture";
    base_url = "https://stream.example";
    chat_path = "/chat";
    embeddings_path = None;
    auth_headers = (fun _ -> []);
    capabilities =
      {
        streaming = true;
        tools = true;
        tool_choice = false;
        structured_outputs = false;
        text = true;
        image_input = false;
        audio_input = false;
        video_input = false;
        embeddings = false;
        image_generation = false;
        speech = false;
        transcription = false;
        rerank = false;
        video_generation = false;
      };
    encode_chat = (fun _ -> Ok "{}");
    decode_chat =
      (fun _ ->
        Ok
          {
            id = None;
            model = None;
            message = Assistant { content = []; tool_calls = [] };
            finish_reasons = [];
            usage = None;
            replay_items = [];
            raw = None;
          });
    encode_embeddings =
      (fun _ ->
        Error
          (Unsupported { provider = "stream-fixture"; feature = "embeddings" }));
    decode_embeddings =
      (fun _ ->
        Error
          (Unsupported { provider = "stream-fixture"; feature = "embeddings" }));
    decode_stream_event =
      (fun event ->
        match (event.event, event.data) with
        | _, "[DONE]" -> Ok [ Stream_done ]
        | _, data when starts_with ~prefix:"text:" data ->
            Ok [ Stream_content_delta (drop_prefix ~prefix:"text:" data) ]
        | Some "content_block_delta", data when starts_with ~prefix:"tool:" data
          ->
            Ok
              [
                Stream_tool_call_delta
                  {
                    index = Some 1;
                    id = Some "toolu_fixture";
                    name = Some "weather";
                    arguments_json_delta = drop_prefix ~prefix:"tool:" data;
                  };
              ]
        | Some "error", data ->
            Ok
              [
                Stream_error
                  (Provider_error
                     {
                       provider = "stream-fixture";
                       status = None;
                       code = Some "stream_error";
                       message = data;
                       raw = Some data;
                       retry_after_s = None;
                     });
              ]
        | _ -> Ok []);
    decode_error =
      (fun ~status ~headers:_ raw ->
        Provider_error
          {
            provider = "stream-fixture";
            status = Some status;
            code = None;
            message = "error";
            raw = Some raw;
            retry_after_s = None;
          });
  }

let stream_text events =
  let buffer = Buffer.create 16 in
  List.iter
    (function
      | Stream_content_delta text -> Buffer.add_string buffer text
      | Stream_message_start _ | Stream_reasoning_delta _
      | Stream_tool_call_delta _ | Stream_response _ | Stream_finish _
      | Stream_error _ | Stream_done ->
          ())
    events;
  Buffer.contents buffer

let stream_tool_args events =
  let buffer = Buffer.create 16 in
  List.iter
    (function
      | Stream_tool_call_delta { arguments_json_delta; _ } ->
          Buffer.add_string buffer arguments_json_delta
      | Stream_message_start _ | Stream_reasoning_delta _
      | Stream_content_delta _ | Stream_response _ | Stream_finish _
      | Stream_error _ | Stream_done ->
          ())
    events;
  Buffer.contents buffer

let stream_errors events =
  List.filter_map
    (function
      | Stream_error (Provider_error { message; _ }) -> Some message
      | Stream_error _ | Stream_message_start _ | Stream_reasoning_delta _
      | Stream_content_delta _ | Stream_tool_call_delta _ | Stream_response _
      | Stream_finish _ | Stream_done ->
          None)
    events

let stream_has_done events =
  List.exists
    (function
      | Stream_done -> true
      | Stream_message_start _ | Stream_reasoning_delta _
      | Stream_content_delta _ | Stream_tool_call_delta _ | Stream_response _
      | Stream_finish _ | Stream_error _ ->
          false)
    events

let contains_substring ~needle value =
  let needle_len = String.length needle in
  let value_len = String.length value in
  let rec loop index =
    needle_len = 0
    || (index + needle_len <= value_len
       && (String.equal needle (String.sub value index needle_len)
          || loop (index + 1)))
  in
  loop 0

let rec sse_concurrent_use = function
  | Eta.Cause.Fail (Decode_error { provider = "stream-fixture"; message; _ })
    ->
      contains_substring ~needle:"concurrent" message
  | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _ -> false
  | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
      List.exists sse_concurrent_use causes
  | Eta.Cause.Finalizer _ -> false
  | Eta.Cause.Suppressed { primary; finalizer } ->
      ignore finalizer;
      sse_concurrent_use primary

let test_stream_reads_partial_chunks_and_done () =
  with_runtime @@ fun rt ->
  let body =
    body_of_string "data: text:Hel\n\ndata: text:lo\n\ndata: [DONE]\n\n"
  in
  let stream = stream_of_body ~max_buffer_bytes:32 stream_provider body in
  let events = run_ok rt "read text stream" (read_stream_events stream) in
  Alcotest.(check string) "text deltas" "Hello" (stream_text events);
  Alcotest.(check bool) "done" true (stream_has_done events)

let test_stream_accepts_chunk_with_many_small_records () =
  with_runtime @@ fun rt ->
  let provider =
    {
      stream_provider with
      decode_stream_event =
        (fun event -> Ok [ Stream_content_delta event.data ]);
    }
  in
  let body =
    Eta_http.Body.Stream.of_bytes
      [ Bytes.of_string "data: a\n\ndata: b\n\ndata: c\n\n" ]
  in
  let stream = stream_of_body ~max_buffer_bytes:12 provider body in
  let events = run_ok rt "read compact stream chunk" (read_stream_events stream) in
  Alcotest.(check int) "all events decoded" 3 (List.length events);
  Alcotest.(check string) "content" "abc" (stream_text events)

let test_stream_rejects_oversized_complete_record_before_decode () =
  with_runtime @@ fun rt ->
  let decoded = ref 0 in
  let provider =
    {
      stream_provider with
      decode_stream_event =
        (fun _ ->
          incr decoded;
          Ok []);
    }
  in
  let payload = "data: text:" ^ String.make 64 'x' ^ "\n\n" in
  let body = Eta_http.Body.Stream.of_bytes [ Bytes.of_string payload ] in
  let stream = stream_of_body ~max_buffer_bytes:32 provider body in
  let provider_name, message, _raw =
    expect_decode_error rt "oversized SSE record" (read_stream_events stream)
  in
  Alcotest.(check string) "provider" "stream-fixture" provider_name;
  Alcotest.(check bool) "mentions cap" true (String.contains message '3');
  Alcotest.(check int) "decoder not called" 0 !decoded

let test_stream_handles_named_tool_deltas () =
  with_runtime @@ fun rt ->
  let body =
    body_of_string
      "event: content_block_delta\ndata: tool:{\"location\"\n\nevent: content_block_delta\ndata: tool::\"SF\"}\n\n"
  in
  let stream = stream_of_body stream_provider body in
  let events = run_ok rt "read tool stream" (read_stream_events stream) in
  Alcotest.(check string) "tool args" "{\"location\":\"SF\"}"
    (stream_tool_args events)

let decode_failing_provider =
  {
    stream_provider with
    decode_stream_event =
      (fun event ->
        Error
          (Decode_error
             {
               provider = "stream-fixture";
               message = "bad stream event";
               raw = Some event.data;
             }));
  }

let chunk_then_eof_body ?release value =
  let reads = ref [ Eta_http.Body.Stream.Chunk (Bytes.of_string value); End ] in
  Eta_http.Body.Stream.of_reader ?release (fun () ->
      match !reads with
      | [] -> Eta.Effect.pure Eta_http.Body.Stream.End
      | next :: rest ->
          reads := rest;
          Eta.Effect.pure next)

let test_stream_decode_error_survives_successful_close () =
  with_runtime @@ fun rt ->
  let body = chunk_then_eof_body "data: bad\n\n" in
  let stream = stream_of_body decode_failing_provider body in
  let provider, message, raw =
    expect_decode_error rt "decode error with close" (read_stream_events stream)
  in
  Alcotest.(check string) "provider" "stream-fixture" provider;
  Alcotest.(check string) "message" "bad stream event" message;
  Alcotest.(check (option string)) "raw" (Some "bad") raw

let test_stream_decode_error_suppresses_close_failure () =
  with_runtime @@ fun rt ->
  let close_error =
    Eta_http.Error.make ~method_:"GET" ~uri:"https://stream.example"
      (Eta_http.Error.Connection_closed
         { during = Eta_http.Error.Http_response })
  in
  let body =
    chunk_then_eof_body
      ~release:(fun () -> Eta.Effect.fail close_error)
      "data: bad\n\n"
  in
  let stream = stream_of_body decode_failing_provider body in
  match B.run rt (read_stream_events stream) with
  | Eta.Exit.Error
      (Eta.Cause.Suppressed
        {
          primary =
            Eta.Cause.Fail
              (Decode_error { provider = "stream-fixture"; message; _ });
          finalizer = Eta.Cause.Finalizer.Fail "<typed failure>";
        }) ->
      Alcotest.(check string) "message" "bad stream event" message;
      ignore close_error
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected decode error"

let test_stream_errors_are_events () =
  with_runtime @@ fun rt ->
  let body = body_of_string "event: error\ndata: Overloaded\n\n" in
  let stream = stream_of_body stream_provider body in
  let events = run_ok rt "read error stream" (read_stream_events stream) in
  Alcotest.(check (list string)) "errors" [ "Overloaded" ]
    (stream_errors events)

let test_stream_early_stop_releases_body_once () =
  with_runtime @@ fun rt ->
  let released = ref 0 in
  let body =
    body_of_string
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      "data: text:first\n\ndata: text:second\n\n"
  in
  let stream = stream_of_body stream_provider body in
  let events =
    run_ok rt "read one stream event" (read_stream_events ~max_events:1 stream)
  in
  Alcotest.(check int) "one event" 1 (List.length events);
  Alcotest.(check int) "released once" 1 !released;
  ignore (run_ok rt "close again" (close_stream stream));
  Alcotest.(check int) "still released once" 1 !released

let test_stream_rejects_concurrent_close () =
  with_runtime @@ fun rt ->
  let read_calls = ref 0 in
  let read_started, read_started_resolver = B.create_promise () in
  let read_unblocked = ref false in
  let read_unblock, read_unblock_resolver = B.create_promise () in
  let unblock_read () =
    if not !read_unblocked then (
      read_unblocked := true;
      B.resolve read_unblock_resolver ())
  in
  let body =
    Eta_http.Body.Stream.of_reader (fun () ->
        Eta.Effect.sync (fun () ->
            incr read_calls;
            B.resolve read_started_resolver ())
        |> Eta.Effect.bind (fun () -> B.await_effect read_unblock)
        |> Eta.Effect.map (fun () ->
            Eta_http.Body.Stream.Chunk
              (Bytes.of_string "data: text:first\n\n")))
  in
  let stream = stream_of_body stream_provider body in
  let read = read_stream_event stream in
  let close =
    B.await_effect read_started
    |> Eta.Effect.bind (fun () -> close_stream stream)
    |> Eta.Effect.finally (Eta.Effect.sync unblock_read)
  in
  match B.run rt (Eta.Effect.par read close) with
  | Eta.Exit.Error cause when sse_concurrent_use cause -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected concurrent SSE failure: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "concurrent SSE close succeeded"

let telemetry_request ?(stream = false) () =
  {
    model = "gpt-4o-mini";
    prompt = [ System "stay brief"; User [ Text "hello" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    reasoning = None;
    max_output_tokens = Some 64;
    replay_items = [];
    stream;
  }

let telemetry_response ?(finish_reasons = [ Stop ]) () =
  {
    id = Some "chatcmpl_fixture";
    model = Some "gpt-4o-mini-2024-07-18";
    message = Assistant { content = [ Text "done" ]; tool_calls = [] };
    finish_reasons;
    usage = Some base_usage;
    replay_items = [];
    raw = None;
  }

let span_attr key (span : Eta.Tracer.span) = List.assoc_opt key span.attrs

let require_span_attr span key expected =
  Alcotest.(check (option string)) key (Some expected) (span_attr key span)

let find_span spans name pred =
  match
    List.find_opt
      (fun (span : Eta.Tracer.span) -> String.equal span.name name && pred span)
      spans
  with
  | Some span -> span
  | None -> Alcotest.fail ("missing span: " ^ name)

let test_telemetry_chat_span_records_genai_attrs_only () =
  with_traced_runtime @@ fun rt tracer ->
  let response =
    run_ok rt "chat telemetry"
      (with_chat_span stream_provider (telemetry_request ())
         (Eta.Effect.pure (telemetry_response ())))
  in
  Alcotest.(check (option string)) "response" (Some "chatcmpl_fixture")
    response.id;
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check int) "span count" 1 (List.length spans);
  let span = find_span spans "chat gpt-4o-mini" (fun _ -> true) in
  Alcotest.(check bool) "kind" true (span.kind = Eta.Tracer.Client);
  require_span_attr span "gen_ai.operation.name" "chat";
  require_span_attr span "gen_ai.provider.name" "stream-fixture";
  require_span_attr span "gen_ai.request.model" "gpt-4o-mini";
  require_span_attr span "server.address" "stream.example";
  require_span_attr span "server.port" "443";
  require_span_attr span "gen_ai.response.id" "chatcmpl_fixture";
  require_span_attr span "gen_ai.response.model" "gpt-4o-mini-2024-07-18";
  require_span_attr span "gen_ai.response.finish_reasons" "stop";
  require_span_attr span "gen_ai.usage.input_tokens" "3";
  require_span_attr span "gen_ai.usage.output_tokens" "5";
  Alcotest.(check (option string)) "no input messages" None
    (span_attr "gen_ai.input.messages" span);
  Alcotest.(check (option string)) "no output messages" None
    (span_attr "gen_ai.output.messages" span);
  Alcotest.(check (option string)) "no tool arguments" None
    (span_attr "gen_ai.tool.call.arguments" span)

let test_telemetry_streaming_and_embeddings_spans () =
  with_traced_runtime @@ fun rt tracer ->
  let embeddings : Embedding.request =
    {
      model = "text-embedding-3-small";
      input = Embedding.Text "hello";
      encoding_format = Some "float";
      dimensions = None;
      user = None;
    }
  in
  let embedding_response : Embedding.response =
    {
      id = Some "emb_fixture";
      model = Some "text-embedding-3-small";
      embeddings =
        [
          {
            embedding = Embedding.Float [ 0.1; 0.2 ];
            index = Some 0;
          };
        ];
      usage =
        Some
          {
            input_tokens = Some 9;
            total_tokens = Some 9;
            raw = [];
          };
      raw = None;
    }
  in
  run_ok rt "stream and embeddings telemetry"
    (Eta.Effect.concat
       [
         with_stream_span ~time_to_first_chunk_s:0.037 stream_provider
           (telemetry_request ~stream:true ())
           Eta.Effect.unit;
         with_embeddings_span stream_provider embeddings
           (Eta.Effect.pure embedding_response)
         |> Eta.Effect.map ignore;
       ]);
  let spans = Eta.Tracer.dump tracer in
  let streaming =
    find_span spans "chat gpt-4o-mini" (fun span ->
        span_attr "gen_ai.request.stream" span = Some "true")
  in
  require_span_attr streaming "gen_ai.response.time_to_first_chunk" "0.037";
  let embeddings =
    find_span spans "embeddings text-embedding-3-small" (fun _ -> true)
  in
  require_span_attr embeddings "gen_ai.operation.name" "embeddings";
  require_span_attr embeddings "gen_ai.request.encoding_formats" "float";
  require_span_attr embeddings "gen_ai.usage.input_tokens" "9";
  require_span_attr embeddings "gen_ai.usage.total_tokens" "9"

let test_telemetry_tool_span_parent_and_transport_suppression () =
  with_traced_runtime @@ fun rt tracer ->
  let hidden_http =
    Eta.Effect.named ~kind:Eta.Capabilities.Client "HTTP POST"
      Eta.Effect.unit
    |> suppress_provider_transport_observability
  in
  let body =
    hidden_http
    |> Eta.Effect.bind (fun () ->
           with_tool_span ~tool_call_id:"call_weather" ~tool_name:"weather"
             Eta.Effect.unit)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.pure
             (telemetry_response ~finish_reasons:[ Tool_calls ] ()))
  in
  ignore
    (run_ok rt "tool telemetry"
       (with_chat_span stream_provider (telemetry_request ()) body));
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool) "no HTTP span" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
       spans);
  let parent =
    find_span spans "chat gpt-4o-mini" (fun span ->
        span_attr "gen_ai.response.finish_reasons" span = Some "tool_calls")
  in
  let tool = find_span spans "execute_tool weather" (fun _ -> true) in
  require_span_attr tool "gen_ai.operation.name" "execute_tool";
  require_span_attr tool "gen_ai.tool.name" "weather";
  require_span_attr tool "gen_ai.tool.call.id" "call_weather";
  require_span_attr tool "gen_ai.tool.type" "function";
  Alcotest.(check (option int)) "tool parent" (Some parent.span_id)
    tool.parent_id

let test_telemetry_error_type_attr () =
  with_traced_runtime @@ fun rt tracer ->
  let error = Unsupported { provider = "stream-fixture"; feature = "tools" } in
  (match
     B.run rt
       (with_chat_span stream_provider (telemetry_request ())
          (Eta.Effect.fail error))
   with
  | Eta.Exit.Ok _ -> Alcotest.fail "expected telemetry failure"
  | Eta.Exit.Error _ -> ());
  let span =
    find_span (Eta.Tracer.dump tracer) "chat gpt-4o-mini" (fun _ -> true)
  in
  require_span_attr span "error.type" "unsupported";
  match span.status with
  | Eta.Tracer.Error _ -> ()
  | _ -> Alcotest.fail "expected error span status"

let span_contains_secret secret (span : Eta.Tracer.span) =
  contains_substring ~needle:secret span.name
  || List.exists
       (fun (key, value) ->
         contains_substring ~needle:secret key
         || contains_substring ~needle:secret value)
       span.attrs

let log_contains_secret secret (record : Eta.Logger.record) =
  contains_substring ~needle:secret record.body
  || List.exists
       (fun (key, value) ->
         contains_substring ~needle:secret key
         || contains_substring ~needle:secret value)
       record.attrs

let test_api_key_not_recorded_in_spans_or_logs () =
  with_observed_runtime @@ fun rt tracer logger ->
  let secret = "sk-live-secret" in
  let key = api_key secret in
  let body =
    let _headers = stream_provider.auth_headers key in
    Eta.Effect.log
      ~attrs:[ ("authorization", "Bearer " ^ Eta_redacted.value key) ]
      "hidden transport log"
    |> suppress_provider_transport_observability
    |> Eta.Effect.bind (fun () -> Eta.Effect.pure (telemetry_response ()))
  in
  ignore
    (run_ok rt "redacted telemetry"
       (with_chat_span stream_provider (telemetry_request ()) body));
  let spans = Eta.Tracer.dump tracer in
  let logs = Eta.Logger.dump logger in
  Alcotest.(check int) "transport logs suppressed" 0 (List.length logs);
  Alcotest.(check bool) "secret absent from spans" false
    (List.exists (span_contains_secret secret) spans);
  Alcotest.(check bool) "secret absent from logs" false
    (List.exists (log_contains_secret secret) logs)

let tests =
  [
      ( "vocabulary",
        [
          Alcotest.test_case "messages" `Quick test_message_vocabulary;
          Alcotest.test_case "raw tool schema" `Quick
            test_tool_schema_stays_raw_json;
          Alcotest.test_case "audio content variant" `Quick
            test_audio_content_variant;
          Alcotest.test_case "provider error raw body" `Quick
            test_provider_error_preserves_raw_body;
          Alcotest.test_case "api key prints redacted" `Quick
            test_api_key_prints_redacted;
        ] );
      ( "failure",
        [
          Alcotest.test_case "status and code categories" `Quick
            test_project_ai_error_status_and_code_categories;
          Alcotest.test_case "nonretryable quota billing context" `Quick
            test_project_ai_error_nonretryable_quota_billing_context;
          Alcotest.test_case "retry after and transport" `Quick
            test_project_ai_error_retry_after_and_transport;
          Alcotest.test_case "diagnostic redaction and bounding" `Quick
            test_project_ai_error_diagnostic_redaction_and_bounding;
        ] );
      ( "provider",
        [
          Alcotest.test_case "value carries endpoint/auth/codecs" `Quick
            test_provider_value_carries_endpoint_auth_and_codecs;
          Alcotest.test_case "encoder rejects unsupported feature" `Quick
            test_provider_encoder_can_reject_unsupported_features;
          Alcotest.test_case "named stream tool delta" `Quick
            test_provider_stream_decoder_handles_named_tool_delta;
        ] );
      ( "toolkit",
        [
          Alcotest.test_case "registers tools in order" `Quick
            test_toolkit_registers_tools_in_order;
          Alcotest.test_case "rejects duplicates" `Quick
            test_toolkit_rejects_duplicate_names;
          Alcotest.test_case "rejects missing schema" `Quick
            test_toolkit_rejects_missing_schema;
          Alcotest.test_case "preserves raw schema" `Quick
            test_make_toolkit_preserves_raw_schema;
        ] );
      ( "stream",
        [
          Alcotest.test_case "partial chunks and done" `Quick
            test_stream_reads_partial_chunks_and_done;
          Alcotest.test_case "many small records in one chunk" `Quick
            test_stream_accepts_chunk_with_many_small_records;
          Alcotest.test_case "oversized complete record rejected" `Quick
            test_stream_rejects_oversized_complete_record_before_decode;
          Alcotest.test_case "named tool deltas" `Quick
            test_stream_handles_named_tool_deltas;
          Alcotest.test_case "decode error survives close" `Quick
            test_stream_decode_error_survives_successful_close;
          Alcotest.test_case "decode error suppresses close failure" `Quick
            test_stream_decode_error_suppresses_close_failure;
          Alcotest.test_case "error events" `Quick test_stream_errors_are_events;
          Alcotest.test_case "early stop releases body" `Quick
            test_stream_early_stop_releases_body_once;
          Alcotest.test_case "rejects concurrent close" `Quick
            test_stream_rejects_concurrent_close;
        ] );
      ( "telemetry",
        [
          Alcotest.test_case "chat span attrs" `Quick
            test_telemetry_chat_span_records_genai_attrs_only;
          Alcotest.test_case "streaming and embeddings spans" `Quick
            test_telemetry_streaming_and_embeddings_spans;
          Alcotest.test_case "tool parent and HTTP suppression" `Quick
            test_telemetry_tool_span_parent_and_transport_suppression;
          Alcotest.test_case "error type attr" `Quick
            test_telemetry_error_type_attr;
          Alcotest.test_case "api key not recorded" `Quick
            test_api_key_not_recorded_in_spans_or_logs;
        ] );
  ]
end
