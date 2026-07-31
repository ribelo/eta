module A = Eta_ai
module O = Eta_ai_openai
module E = Eta.Effect
module H = Eta_http

module Realtime_transport_contract : sig
  include
    A.Realtime.Transport
      with type session = string
       and type client_event = int
       and type server_event = bool
       and type error = string
       and type scope = unit
       and type connection_options = unit
       and type connection = string
end = struct
  type session = string
  type client_event = int
  type server_event = bool
  type error = string
  type scope = unit
  type connection_options = unit
  type connection = string

  let connect ~scope:() () session = E.pure session
  let send _ _ = E.unit
  let read _ = E.pure (Some true)
  let close _ = E.unit
end

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct

let read_fixture = Eta_ai_test_support.read_fixture
let expect_ok = Eta_ai_test_support.expect_ok

let expect_unsupported label = function
  | Stdlib.Error (O.Error.Unsupported feature) -> feature
  | Stdlib.Error _ -> Alcotest.fail ("expected Unsupported: " ^ label)
  | Stdlib.Ok _ -> Alcotest.fail ("expected Error: " ^ label)

let expect_invalid_request label = function
  | Stdlib.Error (O.Error.Invalid_request message) -> message
  | Stdlib.Error _ -> Alcotest.fail ("expected Invalid_request: " ^ label)
  | Stdlib.Ok _ -> Alcotest.fail ("expected Error: " ^ label)

let project err = A.project_ai_error (O.Error.to_ai_error err)

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

let chat_request ?reasoning ?(stream = false) () : A.chat_request =
  {
    model = "gpt-4o-mini";
    prompt = [ A.System "stay brief"; A.User [ A.Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    reasoning;
    max_output_tokens = Some 64;
    replay_items = [];
    stream;
  }

let responses_request ?reasoning ?(stream = false) () :
    A.tool A.Responses.request =
  {
    model = "gpt-4o-mini";
    input =
      A.Responses.Messages
        [ A.System "stay brief"; A.User [ A.Text "weather in Warsaw" ] ];
    instructions = None;
    previous_response_id = None;
    store = None;
    include_ = [];
    tools = [ weather_tool () ];
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = Some 64;
    temperature = Some 0.2;
    top_p = None;
    top_k = None;
    min_p = None;
    text = None;
    reasoning =
      Option.map
        (fun effort ->
          {
            A.Responses.effort = Some effort;
            summary = None;
            generate_summary = None;
          })
        reasoning;
    reasoning_effort = None;
    service_tier = None;
    user = None;
    prompt_cache_key = None;
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
  let structured_responses_request =
    {
      (responses_request ()) with
      text =
        Some
          {
            A.Responses.format =
              A.Responses.Json_schema
                {
                  name = output.name;
                  schema = output.schema;
                  strict = output.strict;
                };
          };
    }
  in
  let responses =
    O.encode_responses structured_responses_request
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
      (responses_request ()) with
      input =
        A.Responses.Messages
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

let test_responses_reasoning_levels () =
  let cases =
    [
      (None, None);
      (Some "off", Some {|{"effort":"none"}|});
      (Some "minimal", Some {|{"effort":"minimal"}|});
      (Some "low", Some {|{"effort":"low"}|});
      (Some "medium", Some {|{"effort":"medium"}|});
      (Some "high", Some {|{"effort":"high"}|});
      (Some "xhigh", Some {|{"effort":"xhigh"}|});
      (Some "max", Some {|{"effort":"max"}|});
    ]
  in
  List.iter
    (fun (reasoning, expected) ->
      let raw =
        O.encode_responses (responses_request ?reasoning ())
        |> expect_ok "responses reasoning"
      in
      let json = A.Json.parse raw |> expect_ok "responses reasoning JSON" in
      let actual =
        A.Json.member "reasoning" json |> Option.map A.Json.compact
      in
      Alcotest.(check (option string)) "reasoning" expected actual)
    cases;
  List.iter
    (fun reasoning ->
      O.encode_responses (responses_request ~reasoning ())
      |> expect_invalid_request "invalid reasoning" |> ignore)
    [ ""; " "; "unknown" ];
  O.encode_chat (chat_request ~reasoning:"high" ())
  |> expect_unsupported "Chat Completions reasoning" |> ignore

let test_xairsp_0eyc_2a4x_distinct_polymorphic_request () =
  (* xairsp-0eyc: the same provider-neutral request shape accepts a
     provider-owned tool algebra. xairsp-2a4x: Chat Completions remains a
     separate [chat_request], exercised independently below. *)
  let with_tools tools : string A.Responses.request =
    {
      model = "provider-model";
      input = A.Responses.Text "hello";
      instructions = None;
      previous_response_id = None;
      store = None;
      include_ = [];
      tools;
      tool_choice = None;
      parallel_tool_calls = None;
      max_turns = None;
      max_output_tokens = None;
      temperature = None;
      top_p = None;
      top_k = None;
      min_p = None;
      text = None;
      reasoning = None;
      reasoning_effort = None;
      service_tier = None;
      user = None;
      prompt_cache_key = None;
      replay_items = [];
      stream = false;
    }
  in
  Alcotest.(check int) "provider tools retained" 2
    (List.length (with_tools [ "web_search"; "x_search" ]).tools);
  let responses =
    O.encode_responses
      {
        (responses_request ()) with
        input = A.Responses.Text "hello";
        instructions = Some "stay brief";
        previous_response_id = Some "resp_previous";
        store = Some false;
        include_ = [ "reasoning.encrypted_content" ];
        tool_choice = Some A.Responses.Auto;
        parallel_tool_calls = Some false;
        top_p = Some 0.8;
        text = Some { A.Responses.format = A.Responses.Json_object };
        service_tier = Some "priority";
        user = Some "eta-user";
        prompt_cache_key = Some "eta-cache";
      }
    |> expect_ok "typed Responses request"
  in
  require_contains "text shorthand" ~needle:"\"input\":\"hello\"" responses;
  require_contains "previous response"
    ~needle:"\"previous_response_id\":\"resp_previous\"" responses;
  require_contains "store" ~needle:"\"store\":false" responses;
  require_contains "tool choice" ~needle:"\"tool_choice\":\"auto\"" responses;
  require_contains "typed text format"
    ~needle:"\"text\":{\"format\":{\"type\":\"json_object\"}}" responses;
  let chat = O.encode_chat (chat_request ()) |> expect_ok "distinct chat" in
  require_contains "chat envelope" ~needle:"\"messages\":[" chat;
  Alcotest.(check bool) "chat has no Responses input" false
    (contains ~needle:"\"input\":" chat)

let test_openai_responses_field_policy () =
  List.iter
    (fun (label, request) ->
      match O.encode_responses request with
      | Stdlib.Error (O.Error.Unsupported feature) ->
          require_contains label ~needle:label feature
      | Stdlib.Error _ -> Alcotest.fail ("unexpected " ^ label ^ " rejection")
      | Stdlib.Ok _ -> Alcotest.fail ("expected " ^ label ^ " rejection"))
    [
      ("top_k", { (responses_request ()) with top_k = Some 10 });
      ( "reasoning_effort",
        { (responses_request ()) with reasoning_effort = Some "high" } );
    ]

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

let test_decode_chat_schema_regressions () =
  (match O.decode_chat {|{"choices":[{}]}|} with
  | Stdlib.Error (O.Error.Decode { message; _ }) ->
      require_contains "missing message diagnostic" ~needle:"missing message" message
  | _ -> Alcotest.fail "missing choice message must be a decode failure");
  (match O.decode_chat {|{"choices":[{"message":"bad"}]}|} with
  | Stdlib.Error (O.Error.Decode { message; _ }) ->
      require_contains "non-object message diagnostic" ~needle:"missing message"
        message
  | _ -> Alcotest.fail "non-object choice message must be a decode failure");
  let response =
    O.decode_chat
      {|{"choices":[{"message":{"content":"one"},"finish_reason":"stop"},{"message":{"content":"two"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}|}
    |> expect_ok "multi-choice chat"
  in
  (match response.finish_reasons with
  | [ A.Stop; A.Length ] -> ()
  | _ -> Alcotest.fail "finish reasons from every choice must be retained");
  let usage = Option.get response.usage in
  Alcotest.(check (option string)) "default raw prompt token name" (Some "1")
    (List.assoc_opt "prompt_tokens" usage.raw);
  Alcotest.(check (option string)) "no renamed default input token" None
    (List.assoc_opt "input_tokens" usage.raw);
  let codec_response =
    Eta_ai_openai_codec.decode_chat ~provider:"probe"
      {|{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":5,"total_tokens":9}}|}
    |> expect_ok "direct codec default usage names"
  in
  let codec_usage = Option.get codec_response.usage in
  Alcotest.(check (option string)) "codec default prompt token name" (Some "4")
    (List.assoc_opt "prompt_tokens" codec_usage.raw);
  Alcotest.(check (option string)) "codec default does not rename input token" None
    (List.assoc_opt "input_tokens" codec_usage.raw);
  let tool_response =
    O.decode_chat
      {|{"choices":[{"message":{"tool_calls":[{"function":{"name":"weather","arguments":{"city":"Warsaw"}}}]}}]}|}
    |> expect_ok "missing tool id"
  in
  match assistant_tool_calls tool_response.message with
  | [ call ] ->
      Alcotest.(check string) "missing tool id defaults empty" "" call.id;
      Alcotest.(check string) "non-string arguments retained" "{\"city\":\"Warsaw\"}"
        call.arguments_json
  | _ -> Alcotest.fail "tool call without id must be retained"

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
  Alcotest.(check (option int))
    "cache miss" (Some 0)
    (Option.bind response.usage (fun usage -> usage.A.input_tokens.cache_read));
  Alcotest.(check (option int))
    "cache write not reported" None
    (Option.bind response.usage (fun usage -> usage.A.input_tokens.cache_write));
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
  | Error
      (O.Error.Provider_response
        { code = Some (`String "server_error"); message = Some message; _ }) ->
      Alcotest.(check string) "message" "model crashed" message
  | Error other ->
      Alcotest.failf "wrong error constructor: %s"
        (match other with
        | O.Error.Provider _ -> "provider"
        | O.Error.Provider_response _ -> "provider_response"
        | O.Error.Decode _ -> "decode"
        | O.Error.Unsupported _ -> "unsupported"
        | O.Error.Invalid_tool _ -> "invalid_tool"
        | O.Error.Http _ -> "http"
        | O.Error.Unknown_response _ -> "unknown"
        | O.Error.Invalid_request _ -> "invalid_request")
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
    O.stream_of_body (O.provider ()) (body_of_fixture "responses_stream.sse")
  in
  let events = run_ok rt "read stream fixture" (O.read_stream_events stream) in
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
      (O.responses client ~api_key:(A.api_key "sk-test") (responses_request ()))
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
  let spans = Eta_observability.Tracer.dump tracer in
  Alcotest.(check bool)
    "transport span suppressed" false
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "HTTP POST")
       spans);
  Alcotest.(check bool)
    "chat span emitted" true
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "chat gpt-4o-mini")
       spans)

let test_responses_runner_provider_error () =
  with_runtime @@ fun rt ->
  let decode_error_hit = ref false in
  let base = O.responses_provider () in
  let provider =
    {
      base with
      A.transport =
        {
          base.transport with
          A.decode_error =
            (fun ~status:_ ~headers:_ _ ->
              decode_error_hit := true;
              A.Invalid_request { provider = "wrong"; message = "wrong" });
        };
    }
  in
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
      (O.responses ~provider client ~api_key:(A.api_key "sk-test")
         (responses_request ()))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Provider
          {
            status = 429;
            headers;
            payload =
              Some
                {
                  message = Some "Rate limit reached";
                  type_ = Some "rate_limit_error";
                  code = Some (`String "rate_limit_exceeded");
                  _;
                };
            raw_body;
          } as error)) ->
      Alcotest.(check (option string)) "retry-after header" (Some "9")
        (H.Core.Header.get "retry-after" headers);
      Alcotest.(check bool) "aierr-2b3g raw body retained" true
        (contains ~needle:"Rate limit reached" raw_body);
      let failure = project error in
      Alcotest.(check string)
        "category" "transient"
        (A.ai_error_category_to_string failure.category);
      Alcotest.(check bool) "retryable" true failure.retryable;
      Alcotest.(check (option int)) "retry after" (Some 9)
        failure.retry_after_s;
      Alcotest.(check bool) "message retained in diagnostic" true
        (contains ~needle:"Rate limit reached" failure.diagnostic);
      Alcotest.(check bool) "raw body omitted from diagnostic" false
        (contains ~needle:"raw=" failure.diagnostic);
      Alcotest.(check bool)
        "nominal runner owns non-success decoding" false !decode_error_hit
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<openai-error>"))
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
  | O.Error.Provider
      {
        payload =
          Some { code = Some (`String "rate_limit_exceeded"); _ };
        _;
      } ->
      let failure = project rate_limit in
      Alcotest.(check string)
        "rate limit category" "transient"
        (A.ai_error_category_to_string failure.category);
      Alcotest.(check bool) "rate limit retryable" true failure.retryable
  | _ -> Alcotest.fail "expected rate limit provider error");
  let quota =
    O.decode_error ~status:429 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"You exceeded your current quota\",\"code\":\"insufficient_quota\"}}"
  in
  let quota_failure = project quota in
  Alcotest.(check string)
    "quota category" "quota_budget"
    (A.ai_error_category_to_string quota_failure.category);
  Alcotest.(check bool) "quota not retryable" false quota_failure.retryable;
  let context =
    O.decode_error ~status:400 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens\",\"code\":\"context_length_exceeded\"}}"
  in
  let context_failure = project context in
  Alcotest.(check string)
    "context category" "context_overflow"
    (A.ai_error_category_to_string context_failure.category);
  Alcotest.(check bool) "context not retryable" false context_failure.retryable;
  let billing =
    O.decode_error ~status:400 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"Billing hard limit reached\",\"code\":\"billing_hard_limit_reached\"}}"
  in
  let billing_failure = project billing in
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
         (responses_request ())
      |> E.bind O.read_stream_events)
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
    O.responses_request ~api_key:(A.api_key "sk-test") (responses_request ())
    |> expect_ok "responses request"
  in
  Alcotest.(check string)
    "responses uri" "https://api.openai.com/v1/responses" request.uri;
  require_contains "responses body" ~needle:"\"input\":["
    (request_body_string request);
  let custom : A.tool A.responses_provider =
    {
      transport = O.provider ~base_url:"https://custom.openai.test" ();
      encode_responses = (fun _ -> Stdlib.Ok {|{"custom_encoder":true}|});
    }
  in
  let custom_request =
    O.responses_request ~provider:custom ~api_key:(A.api_key "sk-test")
      (responses_request ())
    |> expect_ok "custom Responses provider"
  in
  Alcotest.(check string)
    "custom transport" "https://custom.openai.test/v1/responses"
    custom_request.uri;
  require_contains "custom encoder" ~needle:"\"custom_encoder\":true"
    (request_body_string custom_request)

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
      (O.Audio.Text_to_speech.create client ~api_key:(A.api_key "sk-test")
         {
           O.Audio.Text_to_speech.model = "gpt-4o-mini-tts";
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
    O.Audio.Speech_to_text.request ~api_key:(A.api_key "sk-test")
      {
        O.Audio.Speech_to_text.model = "gpt-4o-transcribe";
        file =
          {
            A.Audio.filename = "sample.wav";
            content_type = "audio/wav";
            source = A.Audio.bytes (Bytes.of_string "RIFF");
          };
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
    O.Audio.Speech_to_text.decode_response (read_fixture "transcription.json")
    |> expect_ok "transcription fixture"
  in
  Alcotest.(check (option string)) "text" (Some "hello eta") response.text

let test_transcription_request_rejects_multipart_header_injection () =
  let make_request ?(content_type = "audio/wav") ?(extra_fields = []) () =
    {
      O.Audio.Speech_to_text.model = "gpt-4o-transcribe";
      file =
        {
          A.Audio.filename = "sample.wav";
          content_type;
          source = A.Audio.bytes (Bytes.of_string "RIFF");
        };
      language = None;
      prompt = None;
      response_format = None;
      temperature = None;
      extra_fields;
    }
  in
  let field_error =
    O.Audio.Speech_to_text.request ~api_key:(A.api_key "sk-test")
      (make_request ~extra_fields:[ ("bad\r\nname", "value") ] ())
    |> expect_invalid_request "transcription extra field name"
  in
  require_contains "field name error" ~needle:"field name" field_error;
  let content_type_error =
    O.Audio.Speech_to_text.request ~api_key:(A.api_key "sk-test")
      (make_request ~content_type:"audio/wav\r\nX-Injected: yes" ())
    |> expect_invalid_request "transcription content type"
  in
  require_contains "content type error" ~needle:"content type"
    content_type_error

let test_transcription_request_avoids_boundary_collision () =
  let data = Bytes.of_string "RIFF" in
  let digest_boundary = "eta-ai-" ^ Digest.to_hex (Digest.bytes data) in
  let request =
    O.Audio.Speech_to_text.request ~api_key:(A.api_key "sk-test")
      {
        O.Audio.Speech_to_text.model = "gpt-4o-transcribe";
        file =
          {
            A.Audio.filename = "sample.wav";
            content_type = "audio/wav";
            source = A.Audio.bytes data;
          };
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

let test_oabridge_openai_neutral_conversion_and_projection () =
  let neutral_tts : A.Audio.Text_to_speech.request =
    {
      text = "hello";
      voice = "alloy";
      encoding = Some A.Audio.Text_to_speech.Wav;
      speed = Some 1.1;
    }
  in
  let construction = O.Audio.Text_to_speech.of_eta_ai neutral_tts in
  (* oabridge-d348: [construction] has the abstract [request_construction]
     type. The only public path to [request] requires this explicit provider
     configuration, including OpenAI's required model. *)
  let configured =
    O.Audio.Text_to_speech.configure
      { model = "gpt-4o-mini-tts"; instructions = Some "brief"; extra = [] }
      construction
    |> expect_ok "oabridge-pmod/d348 OpenAI TTS configure"
  in
  Alcotest.(check string) "provider model supplied separately"
    "gpt-4o-mini-tts" configured.model;
  Alcotest.(check string) "neutral text converted" "hello" configured.input;
  Alcotest.(check (option string)) "neutral encoding converted" (Some "wav")
    configured.response_format;
  (match
     O.Audio.Text_to_speech.configure
       { model = ""; instructions = None; extra = [] }
       construction
   with
  | Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "oabridge-d348 must not invent a missing OpenAI model");
  let projected =
    O.Audio.Text_to_speech.to_eta_ai
      { O.Audio.Text_to_speech.content_type = Some "audio/wav";
        audio = Bytes.of_string "WAV" }
  in
  Alcotest.(check string) "oabridge-ff14 explicit TTS projection" "WAV"
    (Bytes.to_string projected.audio);
  let upload : A.Audio.upload =
    {
      filename = "sample.wav";
      content_type = "audio/wav";
      source = A.Audio.bytes (Bytes.of_string "RIFF");
    }
  in
  let construction =
    O.Audio.Speech_to_text.of_eta_ai
      { A.Audio.Speech_to_text.upload = upload; language = Some "en" }
  in
  let configured =
    O.Audio.Speech_to_text.configure
      {
        model = "gpt-4o-transcribe";
        prompt = Some "Eta";
        response_format = Some "json";
        temperature = Some 0.0;
        extra_fields = [];
      }
      construction
    |> expect_ok "oabridge-pmod/d348 OpenAI STT configure"
  in
  Alcotest.(check string) "STT provider model supplied separately"
    "gpt-4o-transcribe" configured.model;
  (* oabridge-ff14: every neutral field is decoded from the provider body and
     projected; none is silently dropped. *)
  let body =
    {|{"text":"hello","language":"french","duration":12.5}|}
  in
  let decoded =
    O.Audio.Speech_to_text.decode_response body
    |> expect_ok "oabridge-ff14 STT decode"
  in
  let projected = O.Audio.Speech_to_text.to_eta_ai decoded in
  Alcotest.(check (option string)) "oabridge-ff14 projected text" (Some "hello")
    projected.text;
  Alcotest.(check (option string)) "oabridge-ff14 projected language"
    (Some "french") projected.language;
  Alcotest.(check (option (float 0.0001))) "oabridge-ff14 projected duration"
    (Some 12.5) projected.duration_s;
  let bare =
    O.Audio.Speech_to_text.decode_response {|{"text":"hello"}|}
    |> expect_ok "oabridge-ff14 STT decode without optional fields"
    |> O.Audio.Speech_to_text.to_eta_ai
  in
  Alcotest.(check (option string)) "oabridge-ff14 absent language stays absent"
    None bare.language;
  Alcotest.(check (option (float 0.0001)))
    "oabridge-ff14 absent duration stays absent" None bare.duration_s

let test_chat_and_responses_encode_audio_content () =
  let request =
    {
      (responses_request ()) with
      input = A.Responses.Messages [ A.User [ A.audio_pcm16_base64 "AAE=" ] ];
    }
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
      reasoning = None;
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
    O.Audio.Realtime.Conversation.session ~model:"gpt-realtime-2" ~instructions:"stay brief"
      ~input_audio_format:O.Audio.Realtime.Conversation.Pcm16_24khz
      ~output_audio_format:O.Audio.Realtime.Conversation.G711_ulaw
      ~voice:(O.Audio.Realtime.Conversation.Named "verse")
      ~max_output_tokens:(O.Audio.Realtime.Conversation.Tokens 128) ()
    |> expect_ok "realtime session"
  in
  let raw = O.Audio.Realtime.Conversation.session_to_string session in
  require_contains "realtime type" ~needle:"\"type\":\"realtime\"" raw;
  require_contains "modalities" ~needle:"\"output_modalities\":[\"audio\"]" raw;
  require_contains "pcm format" ~needle:"\"type\":\"audio/pcm\"" raw;
  require_contains "ulaw format" ~needle:"\"type\":\"audio/pcmu\"" raw;
  require_contains "voice" ~needle:"\"voice\":\"verse\"" raw

let test_realtime_client_secret_request () =
  let session =
    O.Audio.Realtime.Conversation.session ~model:"gpt-realtime-2" ()
    |> expect_ok "realtime session"
  in
  let request =
    O.Audio.Realtime.Conversation.client_secret_request ~base_url:"https://api.openai.test"
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
    O.Audio.Realtime.Conversation.client_event_to_string
      (O.Audio.Realtime.Conversation.Input_audio_buffer_append
         { audio; event_id = None })
  in
  require_contains "append type" ~needle:"\"type\":\"input_audio_buffer.append\"" raw;
  require_contains "audio data" ~needle:"\"audio\":\"AAECAw==\"" raw

let test_realtime_decode_server_events () =
  (match
     O.Audio.Realtime.Conversation.decode_server_event
       "{\"type\":\"response.output_audio.delta\",\"delta\":\"abc\"}"
   with
  | Stdlib.Ok (O.Audio.Realtime.Conversation.Response_audio_delta { delta = "abc"; _ }) -> ()
  | _ -> Alcotest.fail "expected audio delta");
  (match
     O.Audio.Realtime.Conversation.decode_server_event
       "{\"type\":\"error\",\"event_id\":\"ev-err\",\"error\":{\"type\":\"invalid_request_error\",\"code\":\"bad_request\",\"message\":\"nope\"}}"
   with
  | Stdlib.Ok
      (O.Audio.Realtime.Conversation.Error
         { code = Some "bad_request"; message = "nope"; _ }) ->
      ()
  | _ -> Alcotest.fail "expected realtime error event");
  match O.Audio.Realtime.Conversation.decode_server_event "{not-json" with
  | Stdlib.Error (O.Audio.Realtime.Conversation.Decode { raw_body = Some "{not-json"; _ }) -> ()
  | Stdlib.Error (O.Audio.Realtime.Conversation.Decode _) -> ()
  | Stdlib.Ok _ -> Alcotest.fail "malformed frame must not succeed"

let test_airealtime_shared_codec_contract () =
  (* airealtime-02ky/5xcr/xem8/6gv2: the shared codec shape keeps OpenAI's
     session and event types and admits binary messages without adding them to
     OpenAI's lossless event algebra. *)
  let session =
    O.Audio.Realtime.Conversation.session ~model:"gpt-realtime-2" ()
    |> expect_ok "realtime session"
  in
  (match O.Audio.Realtime.Conversation.Codec.encode_session session with
  | A.Realtime.Text raw ->
      require_contains "session update frame"
        ~needle:"\"type\":\"session.update\"" raw;
      require_contains "provider session" ~needle:"\"model\":\"gpt-realtime-2\""
        raw
  | A.Realtime.Binary _ -> Alcotest.fail "OpenAI session must encode as text");
  match
    O.Audio.Realtime.Conversation.Codec.decode_server_event
      (A.Realtime.Binary (Bytes.of_string "\000\001"))
  with
  | Stdlib.Error (O.Audio.Realtime.Conversation.Decode { message; _ }) ->
      require_contains "provider binary policy" ~needle:"binary" message
  | Stdlib.Ok _ -> Alcotest.fail "expected OpenAI binary policy error"

let test_airealtime_nfad_transport_lifecycle () =
  (* airealtime-nfad: one shared lifecycle shape exposes scoped connect, typed
     send, typed events, and close while all concrete types remain provider
     owned. *)
  with_runtime @@ fun rt ->
  let connection =
    run_ok rt "shared Realtime connect"
      (Realtime_transport_contract.connect ~scope:() () "provider-session")
  in
  run_ok rt "shared Realtime send"
    (Realtime_transport_contract.send connection 1);
  Alcotest.(check (option bool)) "typed event" (Some true)
    (run_ok rt "shared Realtime read"
       (Realtime_transport_contract.read connection));
  run_ok rt "shared Realtime close"
    (Realtime_transport_contract.close connection)

let tool_image_request () : A.tool A.Responses.request =
  {
    model = "gpt-4o-mini";
    input =
      A.Responses.Messages
      [
        A.User [ A.Text "take screenshot" ];
        A.Tool
          {
            tool_call_id = "call_screenshot";
            content =
              [
                A.Text "Screenshot:";
                A.Image
                  {
                    url = "data:image/png;base64,iVBORw0KGgo=";
                    detail = Some "low";
                  };
              ];
          };
      ];
    tools = [];
    instructions = None;
    previous_response_id = None;
    store = None;
    include_ = [];
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    temperature = None;
    max_output_tokens = Some 100;
    top_p = None;
    top_k = None;
    min_p = None;
    text = None;
    reasoning = None;
    reasoning_effort = None;
    service_tier = None;
    user = None;
    prompt_cache_key = None;
    replay_items = [];
    stream = false;
  }

let test_openai_responses_tool_result_image_wire_shape () =
  let raw =
    O.encode_responses (tool_image_request ())
    |> expect_ok "responses tool image"
  in
  require_contains "function output"
    ~needle:
      "\"output\":[{\"type\":\"input_text\",\"text\":\"Screenshot:\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,iVBORw0KGgo=\",\"detail\":\"low\"}]"
    raw

let test_openai_chat_tool_result_image_is_unsupported () =
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
                  A.Image
                    {
                      url = "data:image/png;base64,iVBORw0KGgo=";
                      detail = Some "low";
                    };
                ];
            };
        ];
      tools = [];
      temperature = None;
      reasoning = None;
      max_output_tokens = Some 100;
      replay_items = [];
      stream = false;
    }
  in
  match O.encode_chat request with
  | Stdlib.Error (O.Error.Unsupported "tool result media content") -> ()
  | Stdlib.Error _ -> Alcotest.fail "unexpected Chat Completions error"
  | Stdlib.Ok _ ->
      Alcotest.fail "Chat Completions must reject image-bearing tool results"

let test_openai_responses_user_image_wire_shape () =
  let request : A.tool A.Responses.request =
    {
      model = "gpt-4o";
      input =
        A.Responses.Messages
        [
          A.User
            [
              A.Text "What is in this image?";
              A.Image
                { url = "https://example.com/cat.png"; detail = Some "low" };
            ];
        ];
      tools = [];
      instructions = None;
      previous_response_id = None;
      store = None;
      include_ = [];
      tool_choice = None;
      parallel_tool_calls = None;
      max_turns = None;
      temperature = None;
      max_output_tokens = Some 100;
      top_p = None;
      top_k = None;
      min_p = None;
      text = None;
      reasoning = None;
      reasoning_effort = None;
      service_tier = None;
      user = None;
      prompt_cache_key = None;
      replay_items = [];
      stream = false;
    }
  in
  let raw = O.encode_responses request |> expect_ok "image responses" in
  require_contains "responses image type" ~needle:"\"type\":\"input_image\""
    raw;
  require_contains "responses image_url"
    ~needle:"\"image_url\":\"https://example.com/cat.png\"" raw


let test_decode_models_fixture () =
  let models = O.decode_models (read_fixture "models.json") |> expect_ok "models" in
  let ids = List.map (fun (m : O.model_info) -> m.id) models in
  Alcotest.(check (list string)) "ids" [ "gpt-4.1-mini"; "gpt-4.1" ] ids

let test_decode_models_empty_ok () =
  let models = O.decode_models {|{"data":[]}|} |> expect_ok "empty models" in
  Alcotest.(check int) "empty list" 0 (List.length models)

let test_decode_models_malformed_shape () =
  match O.decode_models {|{"models":[]}|} with
  | Stdlib.Error (O.Error.Decode { message; _ }) ->
      require_contains "shape" ~needle:"data array" message
  | Stdlib.Error _ -> Alcotest.fail "expected decode shape error"
  | Stdlib.Ok _ -> Alcotest.fail "expected malformed shape failure"

let test_list_models_runner () =
  with_runtime @@ fun rt ->
  let api_key = O.credential "oa-secret-key" in
  let captured = ref None in
  let models =
    run_ok rt "list_models"
      (O.list_models
         (test_client (response_of_fixture "models.json") captured)
         ~api_key)
  in
  let ids = List.map (fun (m : O.model_info) -> m.id) models in
  Alcotest.(check (list string)) "ids" [ "gpt-4.1-mini"; "gpt-4.1" ] ids;
  match !captured with
  | None -> Alcotest.fail "missing models request"
  | Some request ->
      Alcotest.(check string) "method" "GET" request.H.Request.method_;
      Alcotest.(check string)
        "uri" "https://api.openai.com/v1/models" request.uri;
      Alcotest.(check (option string))
        "auth" (Some "Bearer oa-secret-key")
        (H.Core.Header.get "authorization" request.headers)

let test_list_models_provider_error_is_safe () =
  with_runtime @@ fun rt ->
  let api_key = O.credential "oa-secret-key" in
  let body =
    {|{"error":{"message":"invalid api key oa-secret-key","type":"invalid_request_error","code":"invalid_api_key"}}|}
  in
  let client =
    test_client
      (response_of_bytes ~status:401
         ~headers:[ ("content-type", "application/json") ]
         body)
      (ref None)
  in
  match B.run rt (O.list_models client ~api_key) with
  | Eta.Exit.Ok _ -> Alcotest.fail "expected provider error"
  | Eta.Exit.Error cause ->
      let diagnostic =
        Format.asprintf "%a"
          (Eta.Cause.pp (fun fmt err ->
               Format.pp_print_string fmt (project err).diagnostic))
          cause
      in
      require_contains "status or invalid" ~needle:"invalid" diagnostic;
      (* Credential must not appear outside the provider message body itself;
         project_ai_error should not invent Authorization headers. *)
      Alcotest.(check bool)
        "no bearer leak" false
        (contains ~needle:"Bearer oa-secret-key" diagnostic)

let test_aierr_openai_lossless_param_code_and_headers () =
  let header_list =
    [
      ("content-type", "application/json");
      ("x-request-id", "req-openai-1");
      ("x-duplicate", "first");
      ("x-duplicate", "second");
      ("retry-after", "3");
    ]
  in
  let headers = H.Core.Header.unsafe_of_list header_list in
  let raw = read_fixture "error_param_code_shapes.json" in
  match O.decode_error ~status:400 ~headers raw with
  | O.Error.Provider
      {
        status = 400;
        headers = retained_headers;
        payload = Some payload;
        raw_body;
      } ->
      Alcotest.(check (option string)) "x-request-id" (Some "req-openai-1")
        (H.Core.Header.get "x-request-id" retained_headers);
      Alcotest.(check (list (pair string string)))
        "ordered duplicate headers remain exact" header_list
        (H.Core.Header.to_list retained_headers);
      Alcotest.(check string) "aierr-2b3g raw body" raw raw_body;
      Alcotest.(check (option string))
        "message" (Some "param and code keep JSON shape") payload.message;
      Alcotest.(check (option string))
        "type" (Some "invalid_request_error") payload.type_;
      (match payload.param with
      | Some (`Assoc fields) ->
          Alcotest.(check bool) "param object retained" true
            (List.exists
               (function "field", `String "tools" -> true | _ -> false)
               fields)
      | _ -> Alcotest.fail "param must remain uncoerced JSON object");
      (match payload.code with
      | Some (`Int 42) -> ()
      | _ -> Alcotest.fail "code must remain uncoerced JSON int");
      require_contains "unknown nested field via full JSON"
        ~needle:"\"extra_unknown\":{\"kept\":true}"
        (A.Json.compact payload.full);
      require_contains "top-level unknown via full JSON"
        ~needle:"\"request_id\":\"req_keep_me\"" (A.Json.compact payload.full);
      (match O.Error.to_ai_error
               (O.Error.Provider
                  {
                    status = 400;
                    headers = retained_headers;
                    payload = Some payload;
                    raw_body;
                  })
       with
      | A.Provider_error
          { provider = "openai"; status = Some 400; retry_after_s = Some 3; _ }
        ->
          ()
      | _ -> Alcotest.fail "aierr-v0dd total neutral projection")
  | _ -> Alcotest.fail "expected lossless provider error"

let test_aierr_openai_null_and_malformed_bodies () =
  let null_raw = read_fixture "error_null_param_code.json" in
  (match O.decode_error ~status:400 ~headers:H.Core.Header.empty null_raw with
  | O.Error.Provider { payload = Some payload; _ } ->
      (match payload.param with
      | Some `Null -> ()
      | _ -> Alcotest.fail "param null retained");
      (match payload.code with
      | Some `Null -> ()
      | _ -> Alcotest.fail "code null retained")
  | _ -> Alcotest.fail "expected provider payload for null param/code");
  match O.decode_error ~status:502 ~headers:H.Core.Header.empty "<html>nope" with
  | O.Error.Unknown_response { status = 502; raw_body; payload = None; _ } as err
    ->
      Alcotest.(check string) "malformed raw body" "<html>nope" raw_body;
      Alcotest.(check string) "classification" "unknown_response"
        (O.Error.classification err)
  | _ -> Alcotest.fail "expected unknown_response for non-JSON body"

let test_aierr_openai_local_codec_and_transport_classes () =
  (* aierr-xe8o: local invalid inputs are Invalid_request; capabilities stay Unsupported. *)
  (match O.structured_output ~name:"" ~schema_json:"{}" () with
  | Stdlib.Error (O.Error.Invalid_tool _) -> ()
  | _ -> Alcotest.fail "empty structured output name is invalid_tool");
  (match O.decode_chat "not-json" with
  | Stdlib.Error (O.Error.Decode _) -> ()
  | _ -> Alcotest.fail "malformed chat body is decode");
  (match O.encode_responses { (responses_request ()) with top_k = Some 1 } with
  | Stdlib.Error (O.Error.Unsupported "top_k") -> ()
  | _ -> Alcotest.fail "unsupported field class");
  (match
     O.encode_image_generation
       {
         A.Image.prompt = "";
         model = None;
         n = None;
         size = None;
         quality = None;
         response_format = None;
         user = None;
         extra = [];
       }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "blank image prompt is Invalid_request");
  (match
     O.Audio.Speech_to_text.request ~api_key:(A.api_key "sk")
       {
         O.Audio.Speech_to_text.model = "m";
         file =
           {
             A.Audio.filename = "a.wav";
             content_type = "audio/wav\r\nX:1";
             source = A.Audio.bytes (Bytes.of_string "RIFF");
           };
         language = None;
         prompt = None;
         response_format = None;
         temperature = None;
         extra_fields = [];
       }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "multipart header injection is Invalid_request");
  let http_err =
    O.Error.Http
      (Eta_http.Error.make ~method_:"POST" ~uri:"https://api.openai.com/v1/responses"
         (Eta_http.Error.Total_request_timeout { timeout_ms = Some 1000 }))
  in
  Alcotest.(check string) "http classification" "http_error"
    (O.Error.classification http_err);
  match O.Error.to_ai_error http_err with
  | A.Eta_http_error _ -> ()
  | _ -> Alcotest.fail "http projects to Eta_http_error"

let test_aierr_openai_stream_open_and_midstream_failures () =
  (* aierr-c4cn/aierr-xe8o: stream open and midstream fail outer Error.t, never
     Stream_error of ai_error. *)
  with_runtime @@ fun rt ->
  let captured = ref None in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let client =
    test_client (response_of_fixture ~status:429 ~headers "error.json") captured
  in
  (match
     B.run rt
       (O.stream_responses client ~api_key:(A.api_key "sk-test")
          (responses_request ()))
   with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Provider { status = 429; _ })) -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "stream open must fail on provider HTTP error"
  | Eta.Exit.Error _ -> Alcotest.fail "unexpected stream-open failure");
  let nested_failed =
    "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"boom\",\"type\":\"server_error\",\"code\":42,\"param\":{\"x\":1},\"extra\":true},\"id\":\"r1\"}}"
  in
  (match
     O.decode_stream_event
       { A.event = Some "response.failed"; data = nested_failed }
   with
  | Stdlib.Error
      (O.Error.Provider_response
        {
          message = Some "boom";
          type_ = Some "server_error";
          code = Some (`Int 42);
          param = Some (`Assoc [ ("x", `Int 1) ]);
          raw = Some raw;
          full = Some full;
          raw_body = Some body;
          _;
        }) ->
      require_contains "nested raw" ~needle:"\"extra\":true" (A.Json.compact raw);
      require_contains "full keeps response" ~needle:"\"id\":\"r1\""
        (A.Json.compact full);
      Alcotest.(check string) "raw_body exact" nested_failed body
  | Stdlib.Ok events ->
      Alcotest.failf "midstream must fail outer result, got %d events"
        (List.length events)
  | Stdlib.Error _ -> Alcotest.fail "expected nested Provider_response");
  let midstream_body =
    "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"mid\",\"code\":\"server_error\"}}}\n\n"
  in
  let stream_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let stream_client =
    test_client
      (response_of_bytes ~status:200 ~headers:stream_headers midstream_body)
      (ref None)
  in
  (match
     B.run rt
       (O.stream_responses stream_client ~api_key:(A.api_key "sk-test")
          (responses_request ())
       |> E.bind O.read_stream_events)
   with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Provider_response { message = Some "mid"; _ })) ->
      ()
  | Eta.Exit.Ok events ->
      Alcotest.failf "read_stream_events must fail midstream, got %d"
        (List.length events)
  | Eta.Exit.Error _ -> Alcotest.fail "unexpected midstream read failure");
  let stream_client2 =
    test_client
      (response_of_bytes ~status:200 ~headers:stream_headers midstream_body)
      (ref None)
  in
  match
    B.run rt
      (O.stream_responses stream_client2 ~api_key:(A.api_key "sk-test")
         (responses_request ())
      |> E.bind (fun stream -> O.read_stream_event stream))
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Provider_response { message = Some "mid"; _ })) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "read_stream_event must fail midstream"
  | Eta.Exit.Error _ -> Alcotest.fail "unexpected singular midstream failure"

let test_aierr_openai_total_projection_and_no_fabricated_http () =
  (* aierr-v0dd/aierr-20g2: every case projects; of_ai_error never invents HTTP. *)
  let cases =
    [
      O.Error.Http
        (Eta_http.Error.make ~method_:"GET" ~uri:"u"
           (Eta_http.Error.Connect_error { message = "x" }));
      O.Error.Provider
        {
          status = 400;
          headers = H.Core.Header.unsafe_of_list [ ("a", "1"); ("a", "2") ];
          payload =
            Some
              {
                message = Some "m";
                type_ = Some "t";
                param = Some `Null;
                code = Some (`Int 1);
                raw = `Assoc [ ("message", `String "m") ];
                full = `Assoc [ ("error", `Assoc [ ("message", `String "m") ]) ];
              };
          raw_body = "{}";
        };
      O.Error.Unknown_response
        {
          status = 502;
          headers = H.Core.Header.empty;
          payload = None;
          raw_body = "nope";
        };
      O.Error.Provider_response
        {
          status = None;
          message = Some "failed body";
          type_ = Some "server_error";
          param = None;
          code = Some (`String "server_error");
          raw = None;
          full = None;
          raw_body = Some "{}";
        };
      O.Error.Decode { message = "d"; raw_body = None };
      O.Error.Invalid_request "bad";
      O.Error.Unsupported "feature";
      O.Error.Invalid_tool { name = "t"; message = "m" };
    ]
  in
  List.iter
    (fun err ->
      ignore (O.Error.to_ai_error err);
      ignore (Format.asprintf "%a" O.Error.pp err))
    cases;
  List.iter2
    (fun err expected ->
      Alcotest.(check string) "classification matrix" expected
        (O.Error.classification err))
    cases
    [
      "http_error";
      "t";
      "unknown_response";
      "server_error";
      "decode_error";
      "invalid_request";
      "unsupported";
      "invalid_tool";
    ];
  match
    O.Error.of_ai_error
      (A.Provider_error
         {
           provider = "openai";
           status = Some 418;
           code = Some "teapot";
           message = "short";
           raw = Some "{\"error\":{\"message\":\"short\"}}";
           retry_after_s = None;
         })
  with
  | O.Error.Provider_response { status = Some 418; _ } -> ()
  | O.Error.Provider _ -> Alcotest.fail "must not fabricate HTTP envelope"
  | _ -> Alcotest.fail "expected Provider_response from of_ai_error"

let test_aierr_openai_telemetry_attrs_preserved () =
  with_traced_runtime @@ fun rt tracer ->
  let http =
    Eta_http.Error.make ~method_:"GET" ~uri:"https://probe"
      (Eta_http.Error.Connect_error { message = "down" })
  in
  let neutral_classifications =
    [
      (A.Eta_http_error http, "http_error");
      ( A.Provider_error
          {
            provider = "probe";
            status = None;
            code = Some "remote_code";
            message = "remote";
            raw = None;
            retry_after_s = None;
          },
        "remote_code" );
      ( A.Provider_error
          {
            provider = "probe";
            status = None;
            code = None;
            message = "remote";
            raw = None;
            retry_after_s = None;
          },
        "provider_error" );
      ( A.Decode_error
          { provider = "probe"; message = "decode"; raw = Some "raw" },
        "decode_error" );
      (A.Invalid_request { provider = "probe"; message = "bad" }, "invalid_request");
      (A.Invalid_tool { name = "tool"; message = "bad" }, "invalid_tool");
      (A.Unsupported { provider = "probe"; feature = "video" }, "unsupported");
    ]
  in
  List.iter
    (fun (error, expected) ->
      Alcotest.(check string) "historical neutral error classification" expected
        (A.Provider.Telemetry.ai_error_view.error_type error))
    neutral_classifications;
  let transport = O.provider ~base_url:"https://api.openai.test:8443" () in
  let provider =
    { (O.responses_provider ~base_url:"https://api.openai.test:8443" ()) with
      A.transport }
  in
  let client =
    test_client ~with_http_span:true
      (response_of_fixture "responses.json")
      (ref None)
  in
  ignore
    (run_ok rt "telemetry responses"
       (O.responses ~provider client ~api_key:(A.api_key "sk-test")
          (responses_request ())));
  let stream_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let stream_client =
    test_client
      (response_of_fixture ~headers:stream_headers "responses_stream.sse")
      (ref None)
  in
  ignore
    (run_ok rt "telemetry stream"
       (O.stream_responses ~provider stream_client ~api_key:(A.api_key "sk-test")
          (responses_request ())
       |> E.bind O.read_stream_events));
  let embedding_provider = O.provider ~base_url:"https://api.openai.test:8443" () in
  let embedding_client =
    test_client (response_of_fixture "embeddings.json") (ref None)
  in
  ignore
    (run_ok rt "telemetry embeddings"
       (O.embeddings ~provider:embedding_provider embedding_client
          ~api_key:(A.api_key "sk-test") (embedding_request ())));
  let error_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let error_client =
    test_client
      (response_of_fixture ~status:429 ~headers:error_headers "error.json")
      (ref None)
  in
  ignore
    (B.run rt
       (O.responses ~provider error_client ~api_key:(A.api_key "sk-test")
          (responses_request ())));
  let spans = Eta.Tracer.dump tracer in
  let chat =
    List.find
      (fun (span : Eta.Tracer.span) -> String.equal span.name "chat gpt-4o-mini")
      spans
  in
  let attrs = chat.attrs in
  check_attr "operation" "chat" attrs "gen_ai.operation.name";
  check_attr "provider" "openai" attrs "gen_ai.provider.name";
  check_attr "request model" "gpt-4o-mini" attrs "gen_ai.request.model";
  check_attr "server address" "api.openai.test" attrs "server.address";
  check_attr "server port" "8443" attrs "server.port";
  check_attr "response id" "resp_fixture" attrs "gen_ai.response.id";
  check_attr "response model" "gpt-4.1-mini-2025-04-14" attrs
    "gen_ai.response.model";
  check_attr "finish reasons" "tool_calls" attrs "gen_ai.response.finish_reasons";
  check_attr "input tokens" "10" attrs "gen_ai.usage.input_tokens";
  check_attr "output tokens" "7" attrs "gen_ai.usage.output_tokens";
  let stream_span =
    List.find
      (fun (span : Eta.Tracer.span) ->
        List.assoc_opt "gen_ai.request.stream" span.attrs = Some "true")
      spans
  in
  check_attr "stream flag" "true" stream_span.attrs "gen_ai.request.stream";
  let embedding_span =
    List.find
      (fun (span : Eta.Tracer.span) ->
        String.equal span.name "embeddings text-embedding-3-small")
      spans
  in
  check_attr "embedding operation" "embeddings" embedding_span.attrs
    "gen_ai.operation.name";
  check_attr "embedding format" "float" embedding_span.attrs
    "gen_ai.request.encoding_formats";
  check_attr "embedding model response" "text-embedding-3-small"
    embedding_span.attrs "gen_ai.response.model";
  check_attr "embedding input usage" "3" embedding_span.attrs
    "gen_ai.usage.input_tokens";
  check_attr "embedding total usage" "3" embedding_span.attrs
    "gen_ai.usage.total_tokens";
  let error_span =
    List.find
      (fun (span : Eta.Tracer.span) ->
        List.assoc_opt "error.type" span.attrs = Some "rate_limit_exceeded")
      spans
  in
  check_attr "error type" "rate_limit_exceeded" error_span.attrs "error.type";
  Alcotest.(check bool) "nested http span suppressed" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
       spans)

let test_aierr_openai_no_parallel_ai_error_public_path () =
  (* aierr-le4v: public decode_error/decode_stream_event stay on Error.t and
     never succeed with Stream_error of ai_error. *)
  (match O.decode_error ~status:400 ~headers:H.Core.Header.empty "{}" with
  | O.Error.Provider _ | O.Error.Unknown_response _ -> ()
  | _ -> Alcotest.fail "decode_error must return nominal Error.t");
  match
    O.decode_stream_event
      { A.event = None; data = "{\"error\":{\"message\":\"x\"}}" }
  with
  | Stdlib.Error (O.Error.Provider_response _) -> ()
  | Stdlib.Ok _ -> Alcotest.fail "must not embed Stream_error"
  | Stdlib.Error _ -> Alcotest.fail "expected Provider_response"

let test_aierr_openai_configured_callbacks_run () =
  (* Configured provider encode/decode/stream callbacks must execute. *)
  let encode_hit = ref false in
  let decode_hit = ref false in
  let stream_hit = ref false in
  let base = O.chat_completions_provider () in
  let provider =
    {
      base with
      A.encode_chat =
        (fun req ->
          encode_hit := true;
          base.encode_chat req);
      decode_chat =
        (fun raw ->
          decode_hit := true;
          base.decode_chat raw);
      decode_stream_event =
        (fun event ->
          stream_hit := true;
          base.decode_stream_event event);
    }
  in
  ignore (O.Chat.encode ~provider (chat_request ()) |> expect_ok "callback encode");
  Alcotest.(check bool) "encode callback" true !encode_hit;
  ignore
    (O.Chat.decode ~provider (read_fixture "chat_completion.json")
    |> expect_ok "callback decode");
  Alcotest.(check bool) "decode callback" true !decode_hit;
  with_runtime @@ fun rt ->
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client =
    test_client (response_of_fixture ~headers "stream_tool.sse") (ref None)
  in
  ignore
    (run_ok rt "callback stream"
       (O.Chat.stream ~provider client ~api_key:(A.api_key "sk") (chat_request ())
       |> E.bind O.read_stream_events));
  Alcotest.(check bool) "stream callback" true !stream_hit;
  let stream_headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let stream_client () =
    test_client
      (response_of_bytes ~headers:stream_headers "data: {}\n\n") (ref None)
  in
  let outer =
    {
      base with
      A.decode_stream_event =
        (fun _ ->
          Stdlib.Error
            (A.Decode_error
               { provider = "openai"; message = "outer callback"; raw = None }));
    }
  in
  (match
     B.run rt
       (O.Chat.stream ~provider:outer (stream_client ()) ~api_key:(A.api_key "k")
          (chat_request ())
       |> E.bind O.read_stream_event)
   with
  | Eta.Exit.Error
      (Eta.Cause.Fail (O.Error.Decode { message = "outer callback"; _ })) ->
      ()
  | _ -> Alcotest.fail "outer callback error was not promoted");
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
                     provider = "openai";
                     status = None;
                     code = Some "embedded";
                     message = "embedded callback";
                     raw = Some "{}";
                     retry_after_s = None;
                   });
            ]);
    }
  in
  match
    B.run rt
      (O.Chat.stream ~provider:embedded (stream_client ()) ~api_key:(A.api_key "k")
         (chat_request ())
      |> E.bind O.read_stream_event)
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Provider_response { message = Some "embedded callback"; _ })) ->
      ()
  | _ -> Alcotest.fail "embedded callback error was not promoted"

let test_aierr_openai_callback_matrix () =
  let chat_base = O.chat_completions_provider () in
  let chat_decode_hit = ref false in
  let chat_provider =
    {
      chat_base with
      A.encode_chat = (fun _ -> Stdlib.Ok "{\"chat_callback\":true}");
      decode_chat =
        (fun raw ->
          chat_decode_hit := true;
          match chat_base.decode_chat raw with
          | Stdlib.Ok response ->
              Stdlib.Ok { response with A.model = Some "chat-callback-model" }
          | Stdlib.Error _ as error -> error);
    }
  in
  let chat_request_built =
    O.Chat.request ~provider:chat_provider ~api_key:(A.api_key "k")
      (chat_request ())
    |> expect_ok "chat callback request"
  in
  require_contains "chat encode sentinel" ~needle:"chat_callback"
    (request_body_string chat_request_built);
  let embedding_base = O.chat_completions_provider () in
  let embedding_encode_hit = ref false in
  let embedding_decode_hit = ref false in
  let embedding_provider =
    {
      embedding_base with
      A.embeddings_path = Some "/v1/embeddings";
      encode_embeddings =
        (fun _ ->
          embedding_encode_hit := true;
          Stdlib.Ok "{\"embedding_callback\":true}");
      decode_embeddings =
        (fun raw ->
          embedding_decode_hit := true;
          match
            Eta_ai_openai_codec.decode_embeddings ~provider:"openai" raw
          with
          | Stdlib.Ok response ->
              Stdlib.Ok
                { response with A.Embedding.model = Some "embedding-callback-model" }
          | Stdlib.Error _ as error -> error);
    }
  in
  let embedding_request : A.Embedding.request =
    {
      model = "text-embedding-3-small";
      input = A.Embedding.Text "hello";
      encoding_format = Some "float";
      dimensions = None;
      user = None;
    }
  in
  let embedding_built =
    O.Embeddings.request ~provider:embedding_provider ~api_key:(A.api_key "k")
      embedding_request
    |> expect_ok "embedding callback request"
  in
  require_contains "embedding encode sentinel" ~needle:"embedding_callback"
    (request_body_string embedding_built);
  let responses_base = O.responses_provider () in
  let responses_encode_hit = ref false in
  let responses_decode_hit = ref false in
  let responses_provider =
    {
      A.encode_responses =
        (fun request ->
          responses_encode_hit := true;
          match responses_base.encode_responses request with
          | Stdlib.Ok raw -> (
              match A.Json.parse raw with
              | Stdlib.Ok (`Assoc fields) ->
                  Stdlib.Ok
                    (A.Json.to_string
                       (`Assoc (("responses_callback", `Bool true) :: fields)))
              | _ -> Alcotest.fail "built-in Responses encoder returned non-object")
          | Stdlib.Error _ as error -> error);
      transport =
        {
          responses_base.transport with
          A.decode_chat =
            (fun raw ->
              responses_decode_hit := true;
              match responses_base.transport.decode_chat raw with
              | Stdlib.Ok response ->
                  Stdlib.Ok
                    { response with A.model = Some "responses-callback-model" }
              | Stdlib.Error _ as error -> error);
        };
    }
  in
  let responses_built =
    O.responses_request ~provider:responses_provider ~api_key:(A.api_key "k")
      (responses_request ())
    |> expect_ok "Responses callback request"
  in
  require_contains "Responses encode sentinel" ~needle:"responses_callback"
    (request_body_string responses_built);
  Alcotest.(check bool) "embedding encode callback" true !embedding_encode_hit;
  Alcotest.(check bool) "Responses encode callback" true !responses_encode_hit;
  with_runtime @@ fun rt ->
  let chat_client =
    test_client (response_of_fixture "chat_completion.json") (ref None)
  in
  let chat_response =
    run_ok rt "chat callback run"
      (O.Chat.run ~provider:chat_provider chat_client ~api_key:(A.api_key "k")
         (chat_request ()))
  in
  Alcotest.(check (option string)) "chat decoder sentinel"
    (Some "chat-callback-model") chat_response.model;
  let embedding_client =
    test_client (response_of_fixture "embeddings.json") (ref None)
  in
  let embedding_response =
    run_ok rt "embedding callback run"
      (O.Embeddings.run ~provider:embedding_provider embedding_client
         ~api_key:(A.api_key "k") embedding_request)
  in
  Alcotest.(check (option string)) "embedding decoder sentinel"
    (Some "embedding-callback-model") embedding_response.model;
  let responses_client =
    test_client (response_of_fixture "responses.json") (ref None)
  in
  let responses_response =
    run_ok rt "Responses callback run"
      (O.Chat.responses ~provider:responses_provider responses_client
         ~api_key:(A.api_key "k") (responses_request ()))
  in
  Alcotest.(check (option string)) "Responses decoder sentinel"
    (Some "responses-callback-model") responses_response.model;
  Alcotest.(check bool) "chat decode callback" true !chat_decode_hit;
  Alcotest.(check bool) "embedding decode callback" true !embedding_decode_hit;
  Alcotest.(check bool) "Responses decode callback" true !responses_decode_hit

let test_aierr_openai_custom_invalid_request_stays_provider_response () =
  (* Genuine custom-provider invalid_request is not local Invalid_request. *)
  match
    O.Error.of_ai_error
      (A.Provider_error
         {
           provider = "custom";
           status = None;
           code = Some "invalid_request";
           message = "from provider";
           raw = None;
           retry_after_s = None;
         })
  with
  | O.Error.Provider_response
      { message = Some "from provider"; code = Some (`String "invalid_request"); _ }
    ->
      ()
  | O.Error.Invalid_request _ ->
      Alcotest.fail "must not classify provider invalid_request as local"
  | _ -> Alcotest.fail "expected Provider_response"

let test_aierr_openai_codec_lossless_stream_api () =
  (* aierr-ytbq: codec lossless stream API is provider-neutral. *)
  match
    Eta_ai_openai_codec.decode_stream_event_lossless ~provider:"openai"
      {
        A.event = Some "response.failed";
        data =
          "{\"type\":\"response.failed\",\"error\":{\"message\":\"x\",\"code\":\"c\",\"param\":null}}";
      }
  with
  | Stdlib.Error
      (Eta_ai_openai_codec.Provider
        { payload = { message = Some "x"; param = Some `Null; _ }; _ }) ->
      ()
  | Stdlib.Ok _ -> Alcotest.fail "lossless must fail outer result"
  | Stdlib.Error _ -> Alcotest.fail "expected Provider stream_failure"

let test_aierr_openai_codec_lossless_validation_apis () =
  let module C = Eta_ai_openai_codec in
  (match C.reasoning_level_of_string_lossless "high" with
  | Stdlib.Ok C.High -> ()
  | _ -> Alcotest.fail "reasoning lossless success");
  (match C.reasoning_level_of_string_lossless "impossible" with
  | Stdlib.Error (C.Invalid_request _) -> ()
  | _ -> Alcotest.fail "reasoning lossless invalid");
  (match C.temperature_json_lossless (Some nan) with
  | Stdlib.Error (C.Invalid_request _) -> ()
  | _ -> Alcotest.fail "temperature lossless invalid");
  (match C.optional_float_json_lossless "top_p" (Some infinity) with
  | Stdlib.Error (C.Invalid_request _) -> ()
  | _ -> Alcotest.fail "optional float lossless invalid");
  let schema_value _ raw =
    match A.Json.parse raw with
    | Stdlib.Ok json ->
        (Stdlib.Ok json : (A.Json.t, C.codec_failure) result)
    | Stdlib.Error message ->
        Stdlib.Error (C.Decode { message; raw_body = Some raw })
  in
  (match
     C.structured_output_lossless ~schema_value ~name:"" ~schema_json:"{}" ()
   with
  | Stdlib.Error (C.Invalid_tool _) -> ()
  | _ -> Alcotest.fail "structured output lossless invalid");
  (match
     C.encode_chat_lossless ~schema_value
       { (chat_request ()) with temperature = Some nan }
   with
  | Stdlib.Error (C.Invalid_request _) -> ()
  | _ -> Alcotest.fail "chat lossless invalid");
  (match
     C.encode_chat_lossless
       ~schema_value:(fun _ _ -> Stdlib.Error (C.Invalid_request "sentinel"))
       (chat_request ())
   with
  | Stdlib.Error (C.Invalid_request "sentinel") -> ()
  | _ -> Alcotest.fail "chat schema callback Invalid_request must survive");
  (match C.encode_embeddings_lossless (embedding_request ()) with
  | Stdlib.Ok _ -> ()
  | _ -> Alcotest.fail "embeddings lossless success");
  (match
     C.encode_responses_lossless ~provider:"openai"
       ~map_codec_failure:Fun.id
       ~encode_tool:(fun _ -> Stdlib.Ok (A.Json.object_ []))
       { (responses_request ()) with temperature = Some nan }
   with
  | Stdlib.Error (C.Invalid_request _) -> ()
  | _ -> Alcotest.fail "Responses lossless invalid");
  let check_callback callback assert_error =
    match
      C.encode_responses_lossless ~provider:"openai"
        ~map_codec_failure:O.Error.of_codec_failure
        ~encode_tool:(fun _ -> Stdlib.Error callback)
        (responses_request ())
    with
    | Stdlib.Error actual -> assert_error actual
    | Stdlib.Ok _ -> Alcotest.fail "Responses callback error was discarded"
  in
  check_callback (O.Error.Invalid_request "tool-invalid") (function
    | O.Error.Invalid_request "tool-invalid" -> ()
    | _ -> Alcotest.fail "Responses Invalid_request callback changed");
  check_callback
    (O.Error.Decode { message = "tool-decode"; raw_body = Some "decode-raw" })
    (function
      | O.Error.Decode
          { message = "tool-decode"; raw_body = Some "decode-raw" } -> ()
      | _ -> Alcotest.fail "Responses Decode callback changed");
  check_callback
    (O.Error.Provider_response
       {
         status = Some 409;
         message = Some "tool-provider";
         type_ = Some "conflict";
         param = Some (`Assoc [ ("field", `String "tool") ]);
         code = Some (`Assoc [ ("kind", `String "conflict") ]);
         raw = Some (`Assoc [ ("message", `String "nested") ]);
         full = Some (`Assoc [ ("unknown", `Bool true) ]);
         raw_body = Some "provider-raw";
       })
    (function
      | O.Error.Provider_response
          {
            status = Some 409;
            message = Some "tool-provider";
            type_ = Some "conflict";
            param = Some (`Assoc [ ("field", `String "tool") ]);
            code = Some (`Assoc [ ("kind", `String "conflict") ]);
            raw = Some (`Assoc [ ("message", `String "nested") ]);
            full = Some (`Assoc [ ("unknown", `Bool true) ]);
            raw_body = Some "provider-raw";
          } -> ()
      | _ -> Alcotest.fail "Responses Provider_response callback lost facts");
  let callback_http =
    Eta_http.Error.make ~method_:"POST" ~uri:"https://api.openai.com/v1"
      (Eta_http.Error.Connect_error { message = "tool-transport" })
  in
  check_callback (O.Error.Http callback_http) (function
    | O.Error.Http
        {
          Eta_http.Error.context =
            { method_ = "POST"; uri = "https://api.openai.com/v1"; _ };
          kind = Eta_http.Error.Connect_error { message = "tool-transport" };
        } -> ()
    | _ -> Alcotest.fail "Responses Http callback changed");
  match
    C.encode_speech_lossless ~model:"tts" ~input:"hello" ~voice:"alloy"
      ~speed:nan ()
  with
  | Stdlib.Error (C.Invalid_request _) -> ()
  | _ -> Alcotest.fail "speech lossless invalid"

let test_aierr_openai_validation_classes () =
  (* Oracle A.4: every named validation class. *)
  (match O.encode_chat { (chat_request ()) with temperature = Some nan } with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "non-finite chat temperature");
  (match
     O.encode_embeddings
       {
         model = "text-embedding-3-small";
         input = A.Embedding.Texts [];
         encoding_format = None;
         dimensions = None;
         user = None;
       }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "empty embedding batch");
  (match
     O.encode_embeddings
       {
         model = "text-embedding-3-small";
         input = A.Embedding.Text "x";
         encoding_format = None;
         dimensions = Some 0;
         user = None;
       }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "nonpositive dimensions");
  (match
     O.encode_embeddings
       {
         model = "text-embedding-3-small";
         input = A.Embedding.Text "x";
         encoding_format = Some "binary";
         dimensions = None;
         user = None;
       }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "invalid encoding format");
  (match
     O.encode_embeddings
       {
         model = "text-embedding-3-small";
         input = A.Embedding.Text "x";
         encoding_format = None;
         dimensions = None;
         user = Some "  ";
       }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "blank embedding user");
  (match
     O.encode_responses
       { (responses_request ()) with temperature = Some infinity }
   with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "non-finite responses temperature");
  (match O.encode_responses { (responses_request ()) with top_p = Some nan } with
  | Stdlib.Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "non-finite top_p");
  match O.encode_responses { (responses_request ()) with min_p = Some nan } with
  | Stdlib.Error (O.Error.Unsupported "min_p") -> ()
  | _ -> Alcotest.fail "min_p is unsupported OpenAI field"

let test_aierr_openai_builder_runner_validation () =
  let bad_chat = { (chat_request ()) with temperature = Some nan } in
  let bad_embedding : A.Embedding.request =
    {
      model = "text-embedding-3-small";
      input = A.Embedding.Texts [];
      encoding_format = None;
      dimensions = None;
      user = None;
    }
  in
  let bad_responses =
    { (responses_request ()) with temperature = Some infinity }
  in
  let expect_builder label = function
    | Stdlib.Error (O.Error.Invalid_request _) -> ()
    | _ -> Alcotest.fail (label ^ " builder must return Invalid_request")
  in
  O.chat_completions_request ~api_key:(A.api_key "k") bad_chat
  |> expect_builder "chat";
  O.embeddings_request ~api_key:(A.api_key "k") bad_embedding
  |> expect_builder "embeddings";
  O.responses_request ~api_key:(A.api_key "k") bad_responses
  |> expect_builder "responses";
  with_runtime @@ fun rt ->
  let requests = ref 0 in
  let client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        incr requests;
        E.pure (response_of_fixture "responses.json"))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let expect_runner label eff =
    match B.run rt eff with
    | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Invalid_request _)) -> ()
    | _ -> Alcotest.fail (label ^ " runner must fail Invalid_request")
  in
  expect_runner "chat"
    (O.chat_completions client ~api_key:(A.api_key "k") bad_chat);
  expect_runner "embeddings"
    (O.embeddings client ~api_key:(A.api_key "k") bad_embedding);
  expect_runner "responses"
    (O.responses client ~api_key:(A.api_key "k") bad_responses);
  Alcotest.(check int) "invalid runners never reach transport" 0 !requests

let test_aierr_openai_http_transport_failure () =
  with_runtime @@ fun rt ->
  let client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _req ->
        E.fail
          (Eta_http.Error.make ~method_:"POST"
             ~uri:"https://api.openai.com/v1/responses"
             (Eta_http.Error.Connect_error { message = "refused" })))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  match
    B.run rt
      (O.responses client ~api_key:(A.api_key "sk") (responses_request ()))
  with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Http _)) -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "expected Http transport failure"
  | Eta.Exit.Error _ -> Alcotest.fail "unexpected transport failure shape"

let test_aierr_openai_missing_vs_null_param_code () =
  let missing =
    O.decode_error ~status:400 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"m\"}}"
  in
  let explicit_null =
    O.decode_error ~status:400 ~headers:H.Core.Header.empty
      "{\"error\":{\"message\":\"m\",\"param\":null,\"code\":null}}"
  in
  (match missing with
  | O.Error.Provider { payload = Some { param = None; code = None; _ }; _ } ->
      ()
  | _ -> Alcotest.fail "missing param/code must be None");
  match explicit_null with
  | O.Error.Provider
      { payload = Some { param = Some `Null; code = Some `Null; _ }; _ } ->
      ()
  | _ -> Alcotest.fail "explicit null must remain Some `Null"

let test_aierr_openai_to_ai_error_semantic_fields () =
  (* Every constructor projects to the expected ai_error shape with fields. *)
  let http =
    Eta_http.Error.make ~method_:"POST" ~uri:"https://api.openai.test/v1"
      (Eta_http.Error.Connect_error { message = "refused" })
  in
  (match O.Error.to_ai_error (O.Error.Http http) with
  | A.Eta_http_error projected ->
      Alcotest.(check string) "Http projection identity"
        (Eta_http.Error.to_string http) (Eta_http.Error.to_string projected)
  | _ -> Alcotest.fail "Http projection");
  (match
     O.Error.to_ai_error
       (O.Error.Invalid_request "local bad")
   with
  | A.Invalid_request { provider = "openai"; message = "local bad" } -> ()
  | _ -> Alcotest.fail "Invalid_request projection");
  (match O.Error.to_ai_error (O.Error.Unsupported "feat") with
  | A.Unsupported { provider = "openai"; feature = "feat" } -> ()
  | _ -> Alcotest.fail "Unsupported projection");
  (match
     O.Error.to_ai_error
       (O.Error.Decode { message = "d"; raw_body = Some "{}" })
   with
  | A.Decode_error
      { provider = "openai"; message = "d"; raw = Some "{}" } ->
      ()
  | _ -> Alcotest.fail "Decode projection");
  (match
     O.Error.to_ai_error
       (O.Error.Invalid_tool { name = "t"; message = "m" })
   with
  | A.Invalid_tool { name = "t"; message = "m" } -> ()
  | _ -> Alcotest.fail "Invalid_tool projection");
  (match
     O.Error.to_ai_error
       (O.Error.Unknown_response
          {
            status = 502;
            headers =
              H.Core.Header.unsafe_of_list [ ("retry-after", "4"); ("x", "y") ];
            payload = None;
            raw_body = "<html>bad gateway";
          })
   with
  | A.Provider_error
      {
        provider = "openai";
        status = Some 502;
        code = None;
        message = "Unrecognized OpenAI error response";
        raw = Some "<html>bad gateway";
        retry_after_s = Some 4;
      } ->
      ()
  | _ -> Alcotest.fail "Unknown_response projection");
  let headers =
    H.Core.Header.unsafe_of_list [ ("x-a", "1"); ("x-a", "2"); ("x-b", "3") ]
  in
  (match
     O.Error.to_ai_error
       (O.Error.Provider
          {
            status = 400;
            headers;
            payload =
              Some
                {
                  message = Some "m";
                  type_ = Some "invalid_request_error";
                  param = Some (`String "p");
                  code = Some (`String "c");
                  raw = `Assoc [ ("message", `String "m") ];
                  full =
                    `Assoc
                      [
                        ( "error",
                          `Assoc [ ("message", `String "m") ] );
                      ];
                };
            raw_body = "{\"error\":{\"message\":\"m\"}}";
          })
   with
  | A.Provider_error
      {
        provider = "openai";
        status = Some 400;
        code = Some "c";
        message = "m";
        raw = Some raw;
        _;
      } ->
      require_contains "provider raw retained" ~needle:"message" raw
  | _ -> Alcotest.fail "Provider projection");
  match
    O.Error.to_ai_error
      (O.Error.Provider_response
         {
           status = None;
           message = Some "failed";
           type_ = Some "server_error";
           param = None;
           code = Some (`String "server_error");
           raw = None;
           full = None;
           raw_body = Some "{}";
         })
  with
  | A.Provider_error
      {
        provider = "openai";
        status = None;
        message = "failed";
        code = Some "server_error";
        raw = Some "{}";
        _;
      } ->
      ()
  | _ -> Alcotest.fail "Provider_response projection"

let test_aierr_openai_responses_replay_invalid_request () =
  (* Replay local validation is Invalid_request, not Unsupported. *)
  let bad_item = "{\"type\":\"message\"}" in
  (match
     O.encode_responses
       {
         (responses_request ()) with
         replay_items = [ bad_item ];
       }
   with
  | Stdlib.Error (O.Error.Invalid_request message) ->
      require_contains "replay item type" ~needle:"reasoning" message
  | Stdlib.Error (O.Error.Unsupported _) ->
      Alcotest.fail "replay item must not be Unsupported"
  | _ -> Alcotest.fail "expected Invalid_request for non-reasoning replay");
  (match
     O.encode_responses
       {
         (responses_request ()) with
         input = A.Responses.Text "hi";
         replay_items = [ "{\"type\":\"reasoning\"}" ];
       }
   with
  | Stdlib.Error (O.Error.Invalid_request message) ->
      require_contains "text+replay" ~needle:"text input" message
  | _ -> Alcotest.fail "text input + replay is Invalid_request");
  (match
     O.encode_responses
       { (responses_request ()) with replay_items = [ "{not-json" ] }
   with
  | Stdlib.Error (O.Error.Decode { raw_body = Some "{not-json"; _ }) -> ()
  | _ -> Alcotest.fail "malformed replay JSON is Decode");
  match
    O.encode_responses
      {
        (responses_request ()) with
        input =
          A.Responses.Messages [ A.User [ A.Text "only user" ] ];
        replay_items = [ "{\"type\":\"reasoning\"}" ];
      }
  with
  | Stdlib.Error (O.Error.Invalid_request message) ->
      require_contains "missing tool call" ~needle:"tool call" message
  | _ -> Alcotest.fail "replay without assistant tool call is Invalid_request"

let test_aierr_openai_structured_output_honors_custom_encode () =
  let encode_hit = ref false in
  let base = O.chat_completions_provider () in
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
    O.structured_output ~name:"weather_answer" ~schema_json:weather_schema ()
    |> expect_ok "structured"
  in
  let request =
    O.chat_completions_request ~structured_output:structured ~provider
      ~api_key:(A.api_key "sk") (chat_request ())
    |> expect_ok "structured request"
  in
  Alcotest.(check bool) "custom encode ran" true !encode_hit;
  let body =
    match request.body with
    | H.Request.Fixed chunks ->
        Bytes.to_string (Bytes.concat Bytes.empty chunks)
    | _ -> Alcotest.fail "expected fixed body"
  in
  require_contains "response_format injected" ~needle:"response_format" body;
  require_contains "schema name" ~needle:"weather_answer" body;
  let check_invalid encoded expected =
    let provider = { provider with A.encode_chat = (fun _ -> Stdlib.Ok encoded) } in
    match
      O.chat_completions_request ~structured_output:structured ~provider
        ~api_key:(A.api_key "sk") (chat_request ())
    with
    | Stdlib.Error error -> expected error
    | Stdlib.Ok _ -> Alcotest.fail "invalid callback JSON accepted"
  in
  check_invalid "{bad" (function
    | O.Error.Decode { raw_body = Some "{bad"; _ } -> ()
    | _ -> Alcotest.fail "malformed callback JSON must Decode");
  check_invalid "[]" (function
    | O.Error.Invalid_request _ -> ()
    | _ -> Alcotest.fail "non-object callback JSON must be Invalid_request")

let test_aierr_openai_stream_cleanup_preserves_primary () =
  (* Midstream failure closes exactly once; finalizer failure/defect cannot
     replace the provider failure that triggered cleanup. *)
  with_runtime @@ fun rt ->
  let midstream_body =
    "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"primary-mid\"}}}\n\n"
  in
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let rec has_primary = function
    | Eta.Cause.Fail
        (O.Error.Provider_response { message = Some "primary-mid"; _ }) ->
        true
    | Eta.Cause.Suppressed { primary; _ } -> has_primary primary
    | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
        List.exists has_primary causes
    | Eta.Cause.Die _ | Eta.Cause.Interrupt _ | Eta.Cause.Finalizer _
    | Eta.Cause.Fail _ ->
        false
  in
  let run_case label release =
    let released = ref 0 in
    let first = ref true in
    let body =
      H.Body.Stream.of_reader
        ~release:(fun () -> incr released; release ())
        (fun () ->
          if !first then (
            first := false;
            E.pure (H.Body.Stream.Chunk (Bytes.of_string midstream_body)))
          else E.pure H.Body.Stream.End)
    in
    let client =
      test_client (H.Response.make ~status:200 ~headers ~body ()) (ref None)
    in
    let exit =
      B.run rt
        (O.stream_responses client ~api_key:(A.api_key "sk-test")
           (responses_request ())
        |> E.bind O.read_stream_event)
    in
    (match exit with
    | Eta.Exit.Error cause ->
        if not (has_primary cause) then
          Alcotest.failf "%s primary missing from %a" label
            (Eta.Cause.pp O.Error.pp) cause
    | Eta.Exit.Ok _ -> Alcotest.fail (label ^ " unexpectedly succeeded"));
    Alcotest.(check int) (label ^ " release exactly once") 1 !released
  in
  run_case "successful cleanup" (fun () -> E.unit);
  run_case "typed cleanup failure" (fun () ->
      E.fail
        (Eta_http.Error.make ~method_:"GET" ~uri:"stream"
           (Eta_http.Error.Connect_error { message = "cleanup typed" })));
  run_case "cleanup defect" (fun () -> E.die_message "cleanup defect")

let test_aierr_openai_outer_and_read_cleanup_preserve_primary () =
  with_runtime @@ fun rt ->
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let base = O.chat_completions_provider () in
  let outer =
    {
      base with
      A.decode_stream_event =
        (fun _ ->
          Stdlib.Error
            (A.Decode_error
               { provider = "openai"; message = "outer-primary"; raw = None }));
    }
  in
  let rec has_outer_primary = function
    | Eta.Cause.Fail (O.Error.Decode { message = "outer-primary"; _ }) -> true
    | Eta.Cause.Suppressed { primary; _ } -> has_outer_primary primary
    | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
        List.exists has_outer_primary causes
    | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _
    | Eta.Cause.Finalizer _ -> false
  in
  let run_outer ~plural label release_effect =
    let releases = ref 0 in
    let first = ref true in
    let body =
      H.Body.Stream.of_reader
        ~release:(fun () -> incr releases; release_effect ())
        (fun () ->
          if !first then (
            first := false;
            E.pure
              (H.Body.Stream.Chunk (Bytes.of_string "data: {}\n\n")))
          else E.pure H.Body.Stream.End)
    in
    let client =
      test_client (H.Response.make ~status:200 ~headers ~body ()) (ref None)
    in
    let read stream =
      if plural then O.read_stream_events stream |> E.map ignore
      else O.read_stream_event stream |> E.map ignore
    in
    (match
       B.run rt
         (O.Chat.stream ~provider:outer client ~api_key:(A.api_key "k")
            (chat_request ())
         |> E.bind read)
     with
    | Eta.Exit.Error cause ->
        Alcotest.(check bool) (label ^ " primary") true
          (has_outer_primary cause)
    | Eta.Exit.Ok _ -> Alcotest.fail (label ^ " unexpectedly succeeded"));
    Alcotest.(check int) (label ^ " release exactly once") 1 !releases
  in
  run_outer ~plural:false "outer typed cleanup" (fun () ->
      E.fail
        (Eta_http.Error.make ~method_:"GET" ~uri:"stream"
           (Eta_http.Error.Connect_error { message = "cleanup-typed" })));
  run_outer ~plural:true "outer defect cleanup plural" (fun () ->
      E.die_message "cleanup-defect");
  let success_releases = ref 0 in
  let body =
    H.Body.Stream.of_reader
      ~release:(fun () -> incr success_releases; E.unit)
      (let first = ref true in
       fun () ->
         if !first then (
           first := false;
           E.pure (H.Body.Stream.Chunk (Bytes.of_string "data: {}\n\n")))
         else E.pure H.Body.Stream.End)
  in
  let quiet = { base with A.decode_stream_event = (fun _ -> Stdlib.Ok []) } in
  let client =
    test_client (H.Response.make ~status:200 ~headers ~body ()) (ref None)
  in
  ignore
    (run_ok rt "plural successful cleanup"
       (O.Chat.stream ~provider:quiet client ~api_key:(A.api_key "k")
          (chat_request ())
       |> E.bind O.read_stream_events));
  Alcotest.(check int) "plural successful release exactly once" 1
    !success_releases;
  let read_error =
    Eta_http.Error.make ~method_:"GET" ~uri:"stream"
      (Eta_http.Error.Connect_error { message = "read-primary" })
  in
  let read_releases = ref 0 in
  let body =
    H.Body.Stream.of_reader
      ~release:(fun () -> incr read_releases; E.die_message "read-cleanup-defect")
      (fun () -> E.fail read_error)
  in
  let client =
    test_client (H.Response.make ~status:200 ~headers ~body ()) (ref None)
  in
  let rec has_read_primary = function
    | Eta.Cause.Fail (O.Error.Http _) -> true
    | Eta.Cause.Suppressed { primary; _ } -> has_read_primary primary
    | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
        List.exists has_read_primary causes
    | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _
    | Eta.Cause.Finalizer _ -> false
  in
  (match
     B.run rt
       (O.Chat.stream ~provider:quiet client ~api_key:(A.api_key "k")
          (chat_request ())
       |> E.bind O.read_stream_event)
   with
  | Eta.Exit.Error cause ->
      if not (has_read_primary cause) then
        Alcotest.failf "body read primary missing from %a"
          (Eta.Cause.pp O.Error.pp) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "body read plus release unexpectedly succeeded");
  Alcotest.(check int) "body read failure releases exactly once" 1 !read_releases

let test_aierr_openai_of_ai_error_invalid_request_roundtrip () =
  match
    O.Error.of_ai_error
      (A.Invalid_request { provider = "openai"; message = "x" })
  with
  | O.Error.Invalid_request "x" -> ()
  | O.Error.Provider_response _ ->
      Alcotest.fail "must not reclassify Invalid_request as Provider_response"
  | _ -> Alcotest.fail "expected Invalid_request roundtrip"

let tests =
  [
      ( "provider",
        [
          Alcotest.test_case "value" `Quick test_provider_value;
          Alcotest.test_case "encode chat and responses" `Quick
            test_encode_chat_and_responses;
          Alcotest.test_case "responses reasoning levels" `Quick
            test_responses_reasoning_levels;
          Alcotest.test_case "xairsp-0eyc/2a4x distinct request" `Quick
            test_xairsp_0eyc_2a4x_distinct_polymorphic_request;
          Alcotest.test_case "OpenAI Responses field policy" `Quick
            test_openai_responses_field_policy;
          Alcotest.test_case "encodes audio content" `Quick
            test_chat_and_responses_encode_audio_content;
          Alcotest.test_case "responses tool result image wire shape" `Quick
            test_openai_responses_tool_result_image_wire_shape;
          Alcotest.test_case "chat tool result image unsupported" `Quick
            test_openai_chat_tool_result_image_is_unsupported;
          Alcotest.test_case "responses user image wire shape" `Quick
            test_openai_responses_user_image_wire_shape;
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
          Alcotest.test_case "chat schema regressions" `Quick
            test_decode_chat_schema_regressions;
          Alcotest.test_case "tool fixture" `Quick test_decode_tool_fixture;
          Alcotest.test_case "responses fixture" `Quick
            test_decode_responses_fixture;
          Alcotest.test_case "responses failed status is error" `Quick
            test_decode_responses_failed_status_is_error;
          Alcotest.test_case "models fixture" `Quick test_decode_models_fixture;
          Alcotest.test_case "models empty ok" `Quick test_decode_models_empty_ok;
          Alcotest.test_case "models malformed shape" `Quick
            test_decode_models_malformed_shape;
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
          Alcotest.test_case "aierr lossless param/code/headers" `Quick
            test_aierr_openai_lossless_param_code_and_headers;
          Alcotest.test_case "aierr null and malformed bodies" `Quick
            test_aierr_openai_null_and_malformed_bodies;
          Alcotest.test_case "aierr local codec transport classes" `Quick
            test_aierr_openai_local_codec_and_transport_classes;
          Alcotest.test_case "aierr stream open and midstream" `Quick
            test_aierr_openai_stream_open_and_midstream_failures;
          Alcotest.test_case "aierr total projection no fabricated http" `Quick
            test_aierr_openai_total_projection_and_no_fabricated_http;
          Alcotest.test_case "aierr telemetry attrs preserved" `Quick
            test_aierr_openai_telemetry_attrs_preserved;
          Alcotest.test_case "aierr no parallel ai_error path" `Quick
            test_aierr_openai_no_parallel_ai_error_public_path;
          Alcotest.test_case "aierr configured callbacks run" `Quick
            test_aierr_openai_configured_callbacks_run;
          Alcotest.test_case "aierr callback matrix" `Quick
            test_aierr_openai_callback_matrix;
          Alcotest.test_case "aierr custom invalid_request stays provider" `Quick
            test_aierr_openai_custom_invalid_request_stays_provider_response;
          Alcotest.test_case "aierr codec lossless stream" `Quick
            test_aierr_openai_codec_lossless_stream_api;
          Alcotest.test_case "aierr codec lossless validation APIs" `Quick
            test_aierr_openai_codec_lossless_validation_apis;
          Alcotest.test_case "aierr missing vs null param/code" `Quick
            test_aierr_openai_missing_vs_null_param_code;
          Alcotest.test_case "aierr validation classes" `Quick
            test_aierr_openai_validation_classes;
          Alcotest.test_case "aierr builder runner validation" `Quick
            test_aierr_openai_builder_runner_validation;
          Alcotest.test_case "aierr http transport failure" `Quick
            test_aierr_openai_http_transport_failure;
          Alcotest.test_case "aierr to_ai_error semantic fields" `Quick
            test_aierr_openai_to_ai_error_semantic_fields;
          Alcotest.test_case "aierr responses replay invalid_request" `Quick
            test_aierr_openai_responses_replay_invalid_request;
          Alcotest.test_case "aierr structured_output honors custom encode" `Quick
            test_aierr_openai_structured_output_honors_custom_encode;
          Alcotest.test_case "aierr stream cleanup preserves primary" `Quick
            test_aierr_openai_stream_cleanup_preserves_primary;
          Alcotest.test_case "aierr outer and read cleanup preserves primary"
            `Quick test_aierr_openai_outer_and_read_cleanup_preserve_primary;
          Alcotest.test_case "aierr of_ai_error invalid_request roundtrip" `Quick
            test_aierr_openai_of_ai_error_invalid_request_roundtrip;
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
          Alcotest.test_case
            "oabridge-pmod/d348/ff14 OpenAI neutral conversion and projection"
            `Quick test_oabridge_openai_neutral_conversion_and_projection;
          Alcotest.test_case "list models runner" `Quick test_list_models_runner;
          Alcotest.test_case "list models provider error is safe" `Quick
            test_list_models_provider_error_is_safe;
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
          Alcotest.test_case "airealtime shared codec contract" `Quick
            test_airealtime_shared_codec_contract;
          Alcotest.test_case "airealtime-nfad transport lifecycle" `Quick
            test_airealtime_nfad_transport_lifecycle;
        ] );
  ]
end
