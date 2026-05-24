open Eta_ai

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

let test_provider_error_preserves_raw_body () =
  let error =
    Provider_error
      {
        provider = "openrouter";
        status = Some 502;
        code = Some "server_error";
        message = "Provider disconnected";
        raw = Some "{\"error\":{\"message\":\"Provider disconnected\"}}";
      }
  in
  match error with
  | Provider_error { provider; status; raw = Some raw; _ } ->
      Alcotest.(check string) "provider" "openrouter" provider;
      Alcotest.(check (option int)) "status" (Some 502) status;
      Alcotest.(check bool) "raw json" true (String.contains raw '{')
  | _ -> Alcotest.fail "expected provider error"

let test_api_key_prints_redacted () =
  let key = api_key "sk-live-secret" in
  let rendered = Format.asprintf "%a" Eta_redacted.pp key in
  Alcotest.(check string) "labelled redaction" "<redacted:api_key>" rendered;
  Alcotest.(check bool) "secret omitted" false
    (String.equal rendered "sk-live-secret")

let base_usage =
  {
    input_tokens = Some 3;
    output_tokens = Some 5;
    total_tokens = Some 8;
    raw = [ ("provider", "fixture") ];
  }

let test_provider_value_carries_endpoint_auth_and_codecs () =
  let provider =
    {
      name = "openai";
      base_url = "https://api.openai.test";
      chat_path = "/v1/chat/completions";
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
        };
      encode_chat =
        (fun request ->
          Ok
            (Printf.sprintf
               "{\"model\":%S,\"stream\":%b,\"message_count\":%d}" request.model
               request.stream (List.length request.prompt)));
      decode_chat =
        (fun raw ->
          Ok
            {
              id = Some "chatcmpl_fixture";
              model = Some "gpt-fixture";
              message = Assistant { content = [ Text "done" ]; tool_calls = [] };
              finish_reasons = [ Stop ];
              usage = Some base_usage;
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
      max_output_tokens = Some 64;
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
            (Option.bind response.usage (fun usage -> usage.input_tokens))
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
      auth_headers = (fun _ -> []);
      capabilities =
        {
          streaming = false;
          tools = false;
          tool_choice = false;
          structured_outputs = false;
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
              raw = None;
            });
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
      max_output_tokens = None;
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
  match find_tool "weather" toolkit with
  | Some tool ->
      Alcotest.(check (option string)) "description"
        (Some "Get weather") tool.description
  | None -> Alcotest.fail "expected registered weather tool"

let test_toolkit_rejects_duplicate_names () =
  let weather = weather_tool () in
  let toolkit =
    empty_toolkit |> add_tool weather |> expect_ok "add weather"
  in
  match add_tool weather toolkit with
  | Error
      (Invalid_tool
        { name = "weather"; message = "tool name already registered" }) ->
      ()
  | _ -> Alcotest.fail "expected duplicate tool rejection"

let test_toolkit_rejects_missing_schema () =
  match make_tool ~name:"bad" ~input_schema_json:" " () with
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

let with_observed_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let logger = Eta.Logger.in_memory () in
  let rt =
    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Eta.Tracer.as_capability tracer)
      ~logger:(Eta.Logger.as_capability logger) ()
  in
  f rt tracer logger

let run_ok rt label effect =
  match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s failed: %s" label
        (Format.asprintf "%a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
           cause)

let expect_decode_error rt label effect =
  match Eta.Runtime.run rt effect with
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
    auth_headers = (fun _ -> []);
    capabilities =
      {
        streaming = true;
        tools = true;
        tool_choice = false;
        structured_outputs = false;
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
            raw = None;
          });
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
          });
  }

let stream_text events =
  let buffer = Buffer.create 16 in
  List.iter
    (function
      | Stream_content_delta text -> Buffer.add_string buffer text
      | Stream_message_start _ | Stream_tool_call_delta _ | Stream_finish _
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
      | Stream_message_start _ | Stream_content_delta _ | Stream_finish _
      | Stream_error _ | Stream_done ->
          ())
    events;
  Buffer.contents buffer

let stream_errors events =
  List.filter_map
    (function
      | Stream_error (Provider_error { message; _ }) -> Some message
      | Stream_error _ | Stream_message_start _ | Stream_content_delta _
      | Stream_tool_call_delta _ | Stream_finish _ | Stream_done ->
          None)
    events

let stream_has_done events =
  List.exists
    (function
      | Stream_done -> true
      | Stream_message_start _ | Stream_content_delta _ | Stream_tool_call_delta _
      | Stream_finish _ | Stream_error _ ->
          false)
    events

let test_stream_reads_partial_chunks_and_done () =
  with_runtime @@ fun rt ->
  let body =
    body_of_string "data: text:Hel\n\ndata: text:lo\n\ndata: [DONE]\n\n"
  in
  let stream = stream_of_body ~max_buffer_bytes:32 stream_provider body in
  let events = run_ok rt "read text stream" (read_stream_events stream) in
  Alcotest.(check string) "text deltas" "Hello" (stream_text events);
  Alcotest.(check bool) "done" true (stream_has_done events)

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

let telemetry_request ?(stream = false) () =
  {
    model = "gpt-4o-mini";
    prompt = [ System "stay brief"; User [ Text "hello" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    stream;
  }

let telemetry_response ?(finish_reasons = [ Stop ]) () =
  {
    id = Some "chatcmpl_fixture";
    model = Some "gpt-4o-mini-2024-07-18";
    message = Assistant { content = [ Text "done" ]; tool_calls = [] };
    finish_reasons;
    usage = Some base_usage;
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
  let embeddings =
    {
      embedding_model = "text-embedding-3-small";
      encoding_format = Some "float";
    }
  in
  let usage = { embedding_input_tokens = Some 9; embedding_raw = [] } in
  run_ok rt "stream and embeddings telemetry"
    (Eta.Effect.concat
       [
         with_stream_span ~time_to_first_chunk_s:0.037 stream_provider
           (telemetry_request ~stream:true ())
           Eta.Effect.unit;
         with_embeddings_span ~usage stream_provider embeddings Eta.Effect.unit;
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
  require_span_attr embeddings "gen_ai.usage.input_tokens" "9"

let test_telemetry_tool_span_parent_and_transport_suppression () =
  with_traced_runtime @@ fun rt tracer ->
  let hidden_http =
    Eta.Effect.named_kind ~kind:Eta.Capabilities.Client "HTTP POST"
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
     Eta.Runtime.run rt
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

let contains_substring ~needle value =
  let needle_len = String.length needle in
  let value_len = String.length value in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > value_len then false
    else if String.sub value index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

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

let () =
  Alcotest.run "eta-ai"
    [
      ( "vocabulary",
        [
          Alcotest.test_case "messages" `Quick test_message_vocabulary;
          Alcotest.test_case "raw tool schema" `Quick
            test_tool_schema_stays_raw_json;
          Alcotest.test_case "provider error raw body" `Quick
            test_provider_error_preserves_raw_body;
          Alcotest.test_case "api key prints redacted" `Quick
            test_api_key_prints_redacted;
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
          Alcotest.test_case "oversized complete record rejected" `Quick
            test_stream_rejects_oversized_complete_record_before_decode;
          Alcotest.test_case "named tool deltas" `Quick
            test_stream_handles_named_tool_deltas;
          Alcotest.test_case "error events" `Quick test_stream_errors_are_events;
          Alcotest.test_case "early stop releases body" `Quick
            test_stream_early_stop_releases_body_once;
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
