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

let openai_chat_request request =
  O.Chat.request ~common:request () |> expect_ok "OpenAI Chat request"

let decode_chat_neutral raw =
  O.decode_chat raw |> Result.map O.Chat.to_eta_ai

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
  | H.Request.Stream _ | H.Request.One_shot_stream _
  | H.Request.Rewindable_stream _ ->
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
  Alcotest.(check bool) "Responses speech" false provider.capabilities.speech;
  Alcotest.(check bool)
    "Responses transcription" false provider.capabilities.transcription;
  Alcotest.(check bool)
    "Chat audio input" true chat_provider.capabilities.audio_input;
  Alcotest.(check bool)
    "Chat audio output" true chat_provider.capabilities.speech;
  Alcotest.(check bool)
    "Chat is not transcription" false chat_provider.capabilities.transcription;
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
    O.encode_chat ~structured_output:output
      (openai_chat_request (chat_request ()))
    |> expect_ok "chat"
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
  O.encode_chat (openai_chat_request (chat_request ~reasoning:"high" ()))
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
  let chat =
    O.encode_chat (openai_chat_request (chat_request ()))
    |> expect_ok "distinct chat"
  in
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
    decode_chat_neutral (read_fixture "chat_completion.json")
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
    {|{"id":"chatcmpl_fractional","object":"chat.completion","created":1,"model":"gpt-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","logprobs":null}],"usage":{"prompt_tokens":1.5,"completion_tokens":2,"total_tokens":3}}|}
  in
  match O.decode_chat raw with
  | Stdlib.Error (O.Error.Decode { raw_body = Some actual; _ }) ->
      Alcotest.(check string) "malformed body retained" raw actual
  | _ -> Alcotest.fail "fractional usage must fail the strict success decoder"

let test_decode_chat_usage_details () =
  let raw =
    {|{"id":"chatcmpl_usage","object":"chat.completion","created":1,"model":"gpt-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","logprobs":null}],"usage":{"prompt_tokens":10,"completion_tokens":8,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":4},"completion_tokens_details":{"reasoning_tokens":3}}}|}
  in
  let response = decode_chat_neutral raw |> expect_ok "chat usage details" in
  let usage = Option.get response.usage in
  Alcotest.(check (option int)) "uncached input is not fabricated" None
    usage.A.input_tokens.uncached;
  Alcotest.(check (option int)) "total input" (Some 10)
    usage.A.input_tokens.total;
  Alcotest.(check (option int)) "cache read" (Some 4)
    usage.A.input_tokens.cache_read;
  Alcotest.(check (option int)) "total output" (Some 8)
    usage.A.output_tokens.total;
  Alcotest.(check (option int)) "text output is not fabricated" None
    usage.A.output_tokens.text;
  Alcotest.(check (option int)) "reasoning output" (Some 3)
    usage.A.output_tokens.reasoning

let test_decode_chat_schema_regressions () =
  (match
     decode_chat_neutral
       {|{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0}]}|}
   with
  | Stdlib.Error (O.Error.Decode { message; _ }) ->
      require_contains "missing message diagnostic" ~needle:"missing message" message
  | _ -> Alcotest.fail "missing choice message must be a decode failure");
  (match
     decode_chat_neutral
       {|{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":"bad"}]}|}
   with
  | Stdlib.Error (O.Error.Decode { message; _ }) ->
      require_contains "non-object message diagnostic" ~needle:"must be an object"
        message
  | _ -> Alcotest.fail "non-object choice message must be a decode failure");
  let response =
    decode_chat_neutral
      {|{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"one"},"finish_reason":"stop","logprobs":null},{"index":1,"message":{"role":"assistant","content":"two"},"finish_reason":"length","logprobs":null}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}|}
    |> expect_ok "multi-choice chat"
  in
  (match response.finish_reasons with
  | [ A.Stop ] -> ()
  | _ -> Alcotest.fail "neutral projection must use only the first choice");
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
  match
    O.decode_chat
      {|{"id":"x","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"type":"function","function":{"name":"weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}|}
  with
  | Stdlib.Error (O.Error.Decode _) -> ()
  | _ -> Alcotest.fail "tool call without id must fail strict decoding"

let test_decode_tool_fixture () =
  let response =
    decode_chat_neutral (read_fixture "chat_tool_completion.json")
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
        | O.Error.Invalid_request _ -> "invalid_request"
        | O.Error.Concurrent_use _ -> "concurrent_use"
        | O.Error.Limit_exceeded _ -> "limit_exceeded")
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

let speech_request ?(model = O.Audio.Text_to_speech.Gpt_4o_mini_tts)
    ?(voice = O.Audio.Voices.Built_in O.Audio.Voices.Alloy) ?instructions
    ?response_format ?speed ?stream_format ?(extra = []) input =
  O.Audio.Text_to_speech.request ~model ~input ~voice ?instructions
    ?response_format ?speed ?stream_format ~extra ()
  |> expect_ok "speech request"

let test_speech_runner () =
  with_runtime @@ fun rt ->
  let captured = ref None in
  let client =
    test_client
      (response_of_bytes ~headers:[ ("Content-Type", "audio/mpeg") ] "MP3")
      captured
  in
  let response =
    let request =
      speech_request ~response_format:O.Audio.Text_to_speech.Mp3 ~speed:1.0
        "hello"
    in
    run_ok rt "speech runner"
      (O.Audio.Text_to_speech.create client ~api_key:(A.api_key "sk-test")
         request)
  in
  Alcotest.(check string) "speech body" "MP3" (Bytes.to_string response.audio);
  Alcotest.(check (option string)) "speech content type" (Some "audio/mpeg")
    response.content_type;
  match !captured with
  | Some request ->
      Alcotest.(check string)
        "uri" "https://api.openai.com/v1/audio/speech" request.uri
      ;
      Alcotest.(check (option string)) "speech omits JSON accept" None
        (H.Core.Header.get "accept" request.headers)
  | None -> Alcotest.fail "expected speech request"

let test_oatts_speech_full_request_vocabulary () =
  let models =
    [
      (O.Audio.Text_to_speech.Tts_1, "tts-1");
      (Tts_1_hd, "tts-1-hd");
      (Gpt_4o_mini_tts, "gpt-4o-mini-tts");
      (Gpt_4o_mini_tts_2025_12_15, "gpt-4o-mini-tts-2025-12-15");
      (Other "future-tts", "future-tts");
    ]
  in
  List.iter
    (fun (model, expected) ->
      let raw = speech_request ~model "hello" |> O.Audio.Text_to_speech.encode
        |> expect_ok "speech model encode" in
      require_contains expected ~needle:("\"model\":\"" ^ expected ^ "\"") raw)
    models;
  let voices =
    [
      (O.Audio.Voices.Alloy, "alloy");
      (Ash, "ash");
      (Ballad, "ballad");
      (Coral, "coral");
      (Echo, "echo");
      (Fable, "fable");
      (Onyx, "onyx");
      (Nova, "nova");
      (Sage, "sage");
      (Shimmer, "shimmer");
      (Verse, "verse");
      (Marin, "marin");
      (Cedar, "cedar");
      (Other "future-voice", "future-voice");
    ]
  in
  List.iter
    (fun (voice, expected) ->
      let raw =
        speech_request ~voice:(O.Audio.Voices.Built_in voice) "hello"
        |> O.Audio.Text_to_speech.encode
        |> expect_ok "speech voice encode"
      in
      require_contains expected ~needle:("\"voice\":\"" ^ expected ^ "\"") raw)
    voices;
  let custom_id =
    O.Audio.Voices.custom_id "voice_1234" |> expect_ok "custom voice ID"
  in
  let custom =
    speech_request ~voice:(O.Audio.Voices.Custom custom_id) "hello"
    |> O.Audio.Text_to_speech.encode
    |> expect_ok "custom voice encode"
  in
  require_contains "custom voice object" ~needle:{|"voice":{"id":"voice_1234"}|}
    custom;
  let formats =
    [
      (O.Audio.Text_to_speech.Mp3, "mp3");
      (Opus, "opus");
      (Aac, "aac");
      (Flac, "flac");
      (Wav, "wav");
      (Pcm, "pcm");
    ]
  in
  List.iter
    (fun (format, expected) ->
      let raw =
        speech_request ~response_format:format "hello"
        |> O.Audio.Text_to_speech.encode
        |> expect_ok "speech format encode"
      in
      require_contains expected
        ~needle:("\"response_format\":\"" ^ expected ^ "\"") raw)
    formats;
  let raw =
    speech_request ~instructions:"warm" ~speed:0.25
      ~stream_format:O.Audio.Text_to_speech.Audio
      ~extra:[ ("future_field", `Bool true) ] "hello"
    |> O.Audio.Text_to_speech.encode
    |> expect_ok "full speech encode"
  in
  List.iter
    (fun needle -> require_contains needle ~needle raw)
    [
      {|"instructions":"warm"|};
      {|"speed":0.25|};
      {|"stream_format":"audio"|};
      {|"future_field":true|};
    ]

let test_oaerr_speech_validation_matrix () =
  let reject label result needle =
    let message = expect_invalid_request label result in
    require_contains label ~needle message
  in
  reject "empty custom voice" (O.Audio.Voices.custom_id " ") "must not be empty";
  reject "empty built-in voice"
    (O.Audio.Text_to_speech.request
       ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:"hello"
       ~voice:(O.Audio.Voices.Built_in (O.Audio.Voices.Other " ")) ())
    "must not be empty";
  reject "empty input"
    (O.Audio.Text_to_speech.request
       ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:""
       ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy) ())
    "must not be empty";
  let unicode_4096 = String.concat "" (List.init 4096 (fun _ -> "é")) in
  ignore (speech_request unicode_4096 : O.Audio.Text_to_speech.request);
  reject "unicode input over max"
    (O.Audio.Text_to_speech.request
       ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts
       ~input:(unicode_4096 ^ "é")
       ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy) ())
    "4096";
  List.iter
    (fun speed ->
      reject (Printf.sprintf "speed %.17g" speed)
        (O.Audio.Text_to_speech.request
           ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy) ~speed ())
        "between 0.25 and 4.0")
    [ 0.249; 4.001; Float.nan; Float.infinity; Float.neg_infinity ];
  ignore (speech_request ~speed:0.25 "lower speed boundary");
  ignore (speech_request ~speed:4.0 "upper speed boundary");
  List.iter
    (fun model ->
      reject "legacy instructions"
        (O.Audio.Text_to_speech.request ~model ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
           ~instructions:"warm" ())
        "instructions";
      reject "legacy SSE"
        (O.Audio.Text_to_speech.request ~model ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
           ~stream_format:O.Audio.Text_to_speech.Sse ())
        "SSE")
    [ O.Audio.Text_to_speech.Tts_1; Tts_1_hd ];
  List.iter
    (fun model ->
      reject "legacy Other instructions"
        (O.Audio.Text_to_speech.request
           ~model:(O.Audio.Text_to_speech.Other model) ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
           ~instructions:"warm" ())
        "instructions";
      reject "legacy Other SSE"
        (O.Audio.Text_to_speech.request
           ~model:(O.Audio.Text_to_speech.Other model) ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
           ~stream_format:O.Audio.Text_to_speech.Sse ())
        "SSE")
    [ "tts-1"; "tts-1-hd" ];
  let legacy_allowed =
    [
      O.Audio.Voices.Alloy;
      Ash;
      Coral;
      Echo;
      Fable;
      Onyx;
      Nova;
      Sage;
      Shimmer;
    ]
  in
  List.iter
    (fun model ->
      List.iter
        (fun voice ->
          ignore
            (speech_request ~model
               ~voice:(O.Audio.Voices.Built_in voice) "legacy voice"))
        legacy_allowed;
      List.iter
        (fun (voice, wire) ->
          reject ("legacy voice " ^ wire)
            (O.Audio.Text_to_speech.request ~model ~input:"hello"
               ~voice:(O.Audio.Voices.Built_in voice) ())
            "voice";
          reject ("legacy Other voice " ^ wire)
            (O.Audio.Text_to_speech.request ~model ~input:"hello"
               ~voice:
                 (O.Audio.Voices.Built_in (O.Audio.Voices.Other wire))
               ())
            "voice")
        [
          (O.Audio.Voices.Ballad, "ballad");
          (Verse, "verse");
          (Marin, "marin");
          (Cedar, "cedar");
        ])
    [ O.Audio.Text_to_speech.Tts_1; Tts_1_hd ];
  List.iter
    (fun input ->
      reject "malformed UTF-8 input"
        (O.Audio.Text_to_speech.request
           ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy) ())
        "UTF-8";
      reject "malformed UTF-8 instructions"
        (O.Audio.Text_to_speech.request
           ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
           ~instructions:input ())
        "UTF-8")
    [ "\xc0\xaf"; "\xed\xa0\x80"; "\xf4\x90\x80\x80" ];
  reject "instructions over max"
    (O.Audio.Text_to_speech.request
       ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:"hello"
       ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
       ~instructions:(String.make 4097 'x') ())
    "4096";
  ignore
    (speech_request ~model:(O.Audio.Text_to_speech.Other "future")
       ~instructions:"warm" ~stream_format:O.Audio.Text_to_speech.Sse "hello"
      : O.Audio.Text_to_speech.request);
  List.iter
    (fun field ->
      reject ("collision " ^ field)
        (O.Audio.Text_to_speech.request
           ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:"hello"
           ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
           ~extra:[ (field, `Null) ] ())
        field)
    [
      "model";
      "input";
      "voice";
      "instructions";
      "response_format";
      "speed";
      "stream_format";
    ]

let test_oatts_raw_stream_chunks_collection_and_release () =
  with_runtime @@ fun rt ->
  let run chunks ~max_bytes =
    let releases = ref 0 in
    let body =
      H.Body.Stream.of_bytes
        ~release:(fun () -> E.sync (fun () -> incr releases))
        chunks
    in
    let client =
      test_client (H.Response.make ~status:200 ~body ()) (ref None)
    in
    let stream =
      run_ok rt "open raw speech"
        (O.Audio.Text_to_speech.stream_audio client
           ~api_key:(A.api_key "key")
           (speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello"))
    in
    let exit = B.run rt (O.Audio.Text_to_speech.collect_audio ~max_bytes stream) in
    (exit, !releases)
  in
  let exact, releases =
    run [ Bytes.of_string "abc"; Bytes.of_string "def" ] ~max_bytes:6
  in
  (match exact with
  | Eta.Exit.Ok bytes ->
      Alcotest.(check string) "exact collector" "abcdef" (Bytes.to_string bytes)
  | Eta.Exit.Error _ -> Alcotest.fail "exact collector failed");
  Alcotest.(check int) "exact collector release" 1 releases;
  let over, releases =
    run [ Bytes.of_string "abc"; Bytes.of_string "def" ] ~max_bytes:5
  in
  (match over with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Limit_exceeded { limit = 5; actual = 6; _ })) ->
      ()
  | _ -> Alcotest.fail "over-limit collector did not fail nominally");
  Alcotest.(check int) "over-limit collector release" 1 releases;
  let negative, releases =
    run [ Bytes.of_string "abc" ] ~max_bytes:(-1)
  in
  (match negative with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Invalid_request _)) -> ()
  | _ -> Alcotest.fail "negative collector limit was accepted");
  Alcotest.(check int) "negative collector release" 1 releases;
  let large = Bytes.make (2 * 1024 * 1024) 'a' in
  let unlimited, releases = run [ large; large ] ~max_bytes:(5 * 1024 * 1024) in
  (match unlimited with
  | Eta.Exit.Ok bytes ->
      Alcotest.(check int) "raw total exceeds parser defaults"
        (4 * 1024 * 1024) (Bytes.length bytes)
  | Eta.Exit.Error _ -> Alcotest.fail "large raw stream failed");
  Alcotest.(check int) "large stream release" 1 releases;
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr releases))
      [ Bytes.of_string "one"; Bytes.of_string "two" ]
  in
  let client =
    test_client (H.Response.make ~status:200 ~body ()) (ref None)
  in
  let stream =
    run_ok rt "open pull stream"
      (O.Audio.Text_to_speech.stream_audio client ~api_key:(A.api_key "key")
         (speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello"))
  in
  let first =
    run_ok rt "raw first chunk" (O.Audio.Text_to_speech.read_audio stream)
  in
  Alcotest.(check (option string)) "raw chunk" (Some "one")
    (Option.map Bytes.to_string first);
  run_ok rt "early close" (O.Audio.Text_to_speech.close_audio stream);
  Alcotest.(check int) "early close release" 1 !releases;
  run_ok rt "idempotent close" (O.Audio.Text_to_speech.close_audio stream);
  Alcotest.(check int) "idempotent close release" 1 !releases

let test_oatts_sse_unknown_bounds_and_release () =
  with_runtime @@ fun rt ->
  List.iter
    (fun bound -> Alcotest.(check bool) "positive default bound" true (bound > 0))
    [
      O.Audio.Text_to_speech.default_max_buffer_bytes;
      O.Audio.Text_to_speech.default_max_json_bytes;
      O.Audio.Text_to_speech.default_max_pending_events;
    ];
  let run ?max_buffer_bytes ?max_json_bytes ?max_pending_events payload =
    let releases = ref 0 in
    let body =
      H.Body.Stream.of_bytes
        ~release:(fun () -> E.sync (fun () -> incr releases))
        [ Bytes.of_string payload ]
    in
    let headers =
      H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
    in
    let client =
      test_client (H.Response.make ~status:200 ~headers ~body ()) (ref None)
    in
    let stream =
      run_ok rt "open speech SSE"
        (O.Audio.Text_to_speech.stream_events ?max_buffer_bytes ?max_json_bytes
           ?max_pending_events client ~api_key:(A.api_key "key")
           (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello"))
    in
    let exit = B.run rt (O.Audio.Text_to_speech.read_event stream) in
    (exit, !releases)
  in
  let raw = {|{"type":"speech.future","nested":{"marker":17},"extra":true}|} in
  let exit, releases = run ("event: ignored\ndata: " ^ raw ^ "\n\n") in
  (match exit with
  | Eta.Exit.Ok
      (Some
        (O.Audio.Text_to_speech.Unknown
          { type_ = "speech.future"; raw = json })) ->
      Alcotest.(check string) "complete unknown JSON" (A.Json.compact (`Assoc [
        ("type", `String "speech.future");
        ("nested", `Assoc [ ("marker", `Int 17) ]);
        ("extra", `Bool true);
      ])) (A.Json.compact json)
  | _ -> Alcotest.fail "unknown SSE event not preserved");
  Alcotest.(check int) "unknown last-chunk release" 1 releases;
  let malformed, releases = run "data: {bad\n\n" in
  (match malformed with
  | Eta.Exit.Error
      (Eta.Cause.Fail (O.Error.Decode { raw_body = Some "{bad"; _ })) ->
      ()
  | _ -> Alcotest.fail "malformed speech SSE did not Decode");
  Alcotest.(check int) "malformed release" 1 releases;
  let oversized, releases =
    run ~max_json_bytes:20
      ("data: "
      ^ {|{"type":"speech.future","payload":"too-large"}|}
      ^ "\n\n")
  in
  (match oversized with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Limit_exceeded { kind; limit = 20; _ })) ->
      require_contains "JSON bound kind" ~needle:"JSON" kind
  | _ -> Alcotest.fail "oversized JSON did not fail nominally");
  Alcotest.(check int) "oversized JSON release" 1 releases;
  let unframed, _ = run ~max_buffer_bytes:8 "data: 123456789" in
  (match unframed with
  | Eta.Exit.Error
      (Eta.Cause.Fail (O.Error.Limit_exceeded { limit = 8; _ })) ->
      ()
  | _ -> Alcotest.fail "unframed override did not apply");
  let two =
    "data: {\"type\":\"one\"}\n\ndata: {\"type\":\"two\"}\n\n"
  in
  let pending, _ = run ~max_pending_events:1 two in
  (match pending with
  | Eta.Exit.Error
      (Eta.Cause.Fail (O.Error.Limit_exceeded { limit = 1; actual = 2; _ })) ->
      ()
  | _ -> Alcotest.fail "pending-event override did not apply");
  let default_unframed, _ =
    run
      (String.make
         (O.Audio.Text_to_speech.default_max_buffer_bytes + 1)
         'x')
  in
  (match default_unframed with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Limit_exceeded
          { limit; actual; _ })) ->
      Alcotest.(check int) "default unframed limit"
        O.Audio.Text_to_speech.default_max_buffer_bytes limit;
      Alcotest.(check int) "default unframed actual" (limit + 1) actual
  | _ -> Alcotest.fail "default unframed bound did not apply");
  let json_payload =
    {|{"type":"large","payload":"|}
    ^ String.make O.Audio.Text_to_speech.default_max_json_bytes 'x'
    ^ {|"}|}
  in
  let default_json, _ =
    run
      ~max_buffer_bytes:(String.length json_payload + 32)
      ("data: " ^ json_payload ^ "\n\n")
  in
  (match default_json with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Limit_exceeded { kind; limit; _ })) ->
      require_contains "default JSON kind" ~needle:"JSON" kind;
      Alcotest.(check int) "default JSON limit"
        O.Audio.Text_to_speech.default_max_json_bytes limit
  | _ -> Alcotest.fail "default JSON bound did not apply");
  let default_pending_payload =
    List.init
      (O.Audio.Text_to_speech.default_max_pending_events + 1)
      (fun index ->
        Printf.sprintf "data: {\"type\":\"event.%d\"}\n\n" index)
    |> String.concat ""
  in
  let default_pending, _ = run default_pending_payload in
  match default_pending with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Limit_exceeded { limit; actual; _ })) ->
      Alcotest.(check int) "default pending limit"
        O.Audio.Text_to_speech.default_max_pending_events limit;
      Alcotest.(check int) "default pending actual" (limit + 1) actual
  | _ -> Alcotest.fail "default pending bound did not apply"

let test_oastr_speech_concurrent_use_and_cancellation () =
  B.with_runtime @@ fun ctx rt ->
  let started, started_resolver = B.create_promise () in
  let gate, gate_resolver = B.create_promise () in
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_reader
      ~release:(fun () -> E.sync (fun () -> incr releases))
      (fun () ->
        E.sync (fun () -> B.try_resolve started_resolver ())
        |> E.bind (fun () -> B.await_effect gate)
        |> E.map (fun () -> H.Body.Stream.Chunk (Bytes.of_string "audio")))
  in
  let client =
    test_client (H.Response.make ~status:200 ~body ()) (ref None)
  in
  let stream =
    run_ok rt "open concurrent raw speech"
      (O.Audio.Text_to_speech.stream_audio client ~api_key:(A.api_key "key")
         (speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello"))
  in
  let first =
    B.fork_run_cancelable ctx rt (O.Audio.Text_to_speech.read_audio stream)
  in
  ignore (B.await started : unit);
  (match B.run rt (O.Audio.Text_to_speech.close_audio stream) with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Concurrent_use "speech audio")) -> ()
  | _ -> Alcotest.fail "second operation did not fail immediately");
  Alcotest.(check int) "concurrent rejection has no release" 0 !releases;
  B.cancel_fiber first;
  (match B.await_cancelable first with
  | `Cancelled | `Returned (Eta.Exit.Error _) -> ()
  | `Returned (Eta.Exit.Ok _) -> Alcotest.fail "cancelled read succeeded");
  Alcotest.(check int) "cancelled read release exactly once" 1 !releases;
  B.try_resolve gate_resolver ();
  let event_started, event_started_resolver = B.create_promise () in
  let event_gate, event_gate_resolver = B.create_promise () in
  let event_releases = ref 0 in
  let event_body =
    H.Body.Stream.of_reader
      ~release:(fun () -> E.sync (fun () -> incr event_releases))
      (fun () ->
        E.sync (fun () -> B.try_resolve event_started_resolver ())
        |> E.bind (fun () -> B.await_effect event_gate)
        |> E.map (fun () ->
               H.Body.Stream.Chunk
                 (Bytes.of_string "data: {\"type\":\"future\"}\n\n")))
  in
  let event_request = ref None in
  let event_client =
    test_client (H.Response.make ~status:200 ~body:event_body ()) event_request
  in
  let events =
    run_ok rt "open concurrent event speech"
      (O.Audio.Text_to_speech.stream_events event_client
         ~api_key:(A.api_key "key")
         (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello"))
  in
  (match !event_request with
  | Some request ->
      Alcotest.(check (option string)) "SSE omits undocumented accept" None
        (H.Core.Header.get "accept" request.headers)
  | None -> Alcotest.fail "SSE request was not executed");
  let event_first =
    B.fork_run_cancelable ctx rt (O.Audio.Text_to_speech.read_event events)
  in
  ignore (B.await event_started : unit);
  (match B.run rt (O.Audio.Text_to_speech.close_events events) with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Concurrent_use "speech SSE")) -> ()
  | _ -> Alcotest.fail "second SSE operation did not fail immediately");
  Alcotest.(check int) "concurrent SSE rejection has no release" 0
    !event_releases;
  B.cancel_fiber event_first;
  ignore (B.await_cancelable event_first);
  B.try_resolve event_gate_resolver ();
  Alcotest.(check int) "cancelled SSE release exactly once" 1 !event_releases;
  B.drain rt

let test_oastr_speech_effect_construction_is_inert () =
  with_runtime @@ fun rt ->
  let requests = ref 0 in
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr releases))
      [ Bytes.of_string "chunk" ]
  in
  let client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        incr requests;
        E.pure (H.Response.make ~status:200 ~body ()))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let open_effect =
    O.Audio.Text_to_speech.stream_audio client ~api_key:(A.api_key "key")
      (speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello")
  in
  Alcotest.(check int) "acquisition construction has no request" 0 !requests;
  let impossible_effects =
    [
      ( "buffer",
        O.Audio.Text_to_speech.stream_events ~max_buffer_bytes:max_int client
          ~api_key:(A.api_key "key")
          (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello") );
      ( "JSON",
        O.Audio.Text_to_speech.stream_events ~max_json_bytes:max_int client
          ~api_key:(A.api_key "key")
          (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello") );
    ]
  in
  List.iter (fun (_, operation) -> ignore operation) impossible_effects;
  Alcotest.(check int)
    "impossible parser allocation construction has no request" 0 !requests;
  List.iter
    (fun (label, operation) ->
      match B.run rt operation with
      | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Invalid_request _)) -> ()
      | exit ->
          Alcotest.failf "%s parser allocation was not nominal: %a" label
            (Eta.Exit.pp
               (fun fmt _ -> Format.pp_print_string fmt "<stream>")
               O.Error.pp)
            exit)
    impossible_effects;
  Alcotest.(check int) "impossible parser allocation acquires no body" 0 !requests;
  let stream = run_ok rt "run inert acquisition" open_effect in
  Alcotest.(check int) "acquisition executes one request" 1 !requests;
  let discarded_close = O.Audio.Text_to_speech.close_audio stream in
  let discarded_collect =
    O.Audio.Text_to_speech.collect_audio ~max_bytes:(-1) stream
  in
  ignore discarded_close;
  ignore discarded_collect;
  Alcotest.(check int) "discarded operations do not release" 0 !releases;
  let chunk =
    run_ok rt "read after discarded operations"
      (O.Audio.Text_to_speech.read_audio stream)
  in
  Alcotest.(check (option string)) "raw state unchanged" (Some "chunk")
    (Option.map Bytes.to_string chunk);
  Alcotest.(check int) "executed last pull releases" 1 !releases;
  let event_releases = ref 0 in
  let event_body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr event_releases))
      [
        Bytes.of_string
          "data: {\"type\":\"first\"}\n\ndata: {\"type\":\"second\"}\n\n";
      ]
  in
  let event_client =
    test_client (H.Response.make ~status:200 ~body:event_body ()) (ref None)
  in
  let events =
    run_ok rt "open pending event stream"
      (O.Audio.Text_to_speech.stream_events event_client
         ~api_key:(A.api_key "key")
         (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello"))
  in
  let first =
    run_ok rt "first pending event"
      (O.Audio.Text_to_speech.read_event events)
  in
  (match first with
  | Some (O.Audio.Text_to_speech.Unknown { type_ = "first"; _ }) -> ()
  | _ -> Alcotest.fail "first event missing");
  let discarded_read = O.Audio.Text_to_speech.read_event events in
  let discarded_close = O.Audio.Text_to_speech.close_events events in
  ignore discarded_read;
  ignore discarded_close;
  let second =
    run_ok rt "pending event after discarded operations"
      (O.Audio.Text_to_speech.read_event events)
  in
  (match second with
  | Some (O.Audio.Text_to_speech.Unknown { type_ = "second"; _ }) -> ()
  | _ -> Alcotest.fail "effect construction popped pending event");
  Alcotest.(check int) "body release remains exact" 1 !event_releases

let test_oastr_speech_close_cancellation_waits_for_release () =
  B.with_runtime @@ fun ctx rt ->
  let check label make_stream close =
    let release_started, release_started_resolver = B.create_promise () in
    let release_gate, release_gate_resolver = B.create_promise () in
    let releases = ref 0 in
    let body =
      H.Body.Stream.of_reader
        ~release:(fun () ->
          E.sync (fun () -> B.try_resolve release_started_resolver ())
          |> E.bind (fun () -> B.await_effect release_gate)
          |> E.bind (fun () -> E.sync (fun () -> incr releases)))
        (fun () -> E.never)
    in
    let stream = make_stream body in
    let first = B.fork_run_cancelable ctx rt (close stream) in
    ignore (B.await release_started : unit);
    B.cancel_fiber first;
    B.yield ();
    (match B.run rt (close stream) with
    | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Concurrent_use _)) -> ()
    | _ ->
        Alcotest.failf "%s close cancellation escaped blocked release" label);
    Alcotest.(check int)
      (label ^ " blocked release has not completed") 0 !releases;
    B.try_resolve release_gate_resolver ();
    (match B.await_cancelable first with
    | `Cancelled
    | `Returned (Eta.Exit.Ok ())
    | `Returned (Eta.Exit.Error (Eta.Cause.Interrupt _)) ->
        ()
    | `Returned exit ->
        Alcotest.failf "%s cancelled close returned unexpectedly: %a" label
          (Eta.Exit.pp
             (fun fmt () -> Format.pp_print_string fmt "()")
             O.Error.pp)
          exit);
    Alcotest.(check int) (label ^ " release completes once") 1 !releases;
    (match B.run rt (close stream) with
    | Eta.Exit.Ok () -> ()
    | _ -> Alcotest.failf "%s subsequent close did not become a no-op" label);
    Alcotest.(check int) (label ^ " subsequent close stays exact") 1 !releases
  in
  check "audio"
    (fun body ->
      let client =
        test_client (H.Response.make ~status:200 ~body ()) (ref None)
      in
      run_ok rt "open audio for blocked close"
        (O.Audio.Text_to_speech.stream_audio client ~api_key:(A.api_key "key")
           (speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello")))
    O.Audio.Text_to_speech.close_audio;
  check "SSE"
    (fun body ->
      let client =
        test_client (H.Response.make ~status:200 ~body ()) (ref None)
      in
      run_ok rt "open SSE for blocked close"
        (O.Audio.Text_to_speech.stream_events client ~api_key:(A.api_key "key")
           (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello")))
    O.Audio.Text_to_speech.close_events;
  let transport =
    Eta_http.Error.make ~method_:"POST" ~uri:"speech-close"
      (Eta_http.Error.Connect_error { message = "release failed" })
  in
  let check_failure label make_stream close =
    let release_attempts = ref 0 in
    let body =
      H.Body.Stream.of_reader
        ~release:(fun () ->
          E.sync (fun () -> incr release_attempts)
          |> E.bind (fun () -> E.fail transport))
        (fun () -> E.never)
    in
    let stream = make_stream body in
    (match B.run rt (close stream) with
    | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Http _)) -> ()
    | _ -> Alcotest.failf "%s close did not preserve typed release failure" label);
    Alcotest.(check int) (label ^ " failing release attempted once") 1
      !release_attempts;
    (match B.run rt (close stream) with
    | Eta.Exit.Ok () -> ()
    | _ -> Alcotest.failf "%s close retried a failed one-shot release" label);
    Alcotest.(check int) (label ^ " failed release remains one-shot") 1
      !release_attempts
  in
  check_failure "audio"
    (fun body ->
      run_ok rt "open audio for failing close"
        (O.Audio.Text_to_speech.stream_audio
           (test_client (H.Response.make ~status:200 ~body ()) (ref None))
           ~api_key:(A.api_key "key")
           (speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello")))
    O.Audio.Text_to_speech.close_audio;
  check_failure "SSE"
    (fun body ->
      run_ok rt "open SSE for failing close"
        (O.Audio.Text_to_speech.stream_events
           (test_client (H.Response.make ~status:200 ~body ()) (ref None))
           ~api_key:(A.api_key "key")
           (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello")))
    O.Audio.Text_to_speech.close_events;
  B.drain rt

let test_oastr_speech_primary_cleanup_precedence () =
  with_runtime @@ fun rt ->
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_reader
      ~release:(fun () ->
        E.sync (fun () -> incr releases)
        |> E.bind (fun () -> E.die_message "speech cleanup defect"))
      (let first = ref true in
       fun () ->
         if !first then begin
           first := false;
           E.pure (H.Body.Stream.Chunk (Bytes.of_string "data: {bad\n\n"))
         end
         else E.pure H.Body.Stream.End)
  in
  let client =
    test_client (H.Response.make ~status:200 ~body ()) (ref None)
  in
  let stream =
    run_ok rt "open failing speech SSE"
      (O.Audio.Text_to_speech.stream_events client ~api_key:(A.api_key "key")
         (speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello"))
  in
  (match B.run rt (O.Audio.Text_to_speech.read_event stream) with
  | Eta.Exit.Error
      (Eta.Cause.Suppressed
        {
          primary =
            Eta.Cause.Fail
              (O.Error.Decode { raw_body = Some "{bad"; _ });
          finalizer = Eta.Cause.Finalizer.Die die;
        }) ->
      Alcotest.(check string) "exact cleanup diagnostic"
        "Failure(\"speech cleanup defect\")"
        (Printexc.to_string die.exn)
  | Eta.Exit.Error cause ->
      Alcotest.failf "cleanup precedence shape was not exact: %a"
        (Eta.Cause.pp O.Error.pp) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "malformed SSE succeeded");
  Alcotest.(check int) "failing cleanup release exactly once" 1 !releases

let test_oaerr_speech_runner_failure_matrix () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let inert_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        incr calls;
        E.pure (response_of_bytes "unused"))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let sse_request =
    speech_request ~stream_format:O.Audio.Text_to_speech.Sse "hello"
  in
  (match
     B.run rt
       (O.Audio.Text_to_speech.create inert_client ~api_key:(A.api_key "key")
          sse_request)
   with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Invalid_request _)) -> ()
  | _ -> Alcotest.fail "create accepted SSE request");
  let audio_request =
    speech_request ~stream_format:O.Audio.Text_to_speech.Audio "hello"
  in
  (match
     B.run rt
       (O.Audio.Text_to_speech.stream_events inert_client
          ~api_key:(A.api_key "key") audio_request)
   with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Invalid_request _)) -> ()
  | _ -> Alcotest.fail "event stream accepted audio request");
  List.iter
    (fun (label, operation) ->
      match B.run rt operation with
      | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Invalid_request _)) -> ()
      | _ -> Alcotest.fail (label ^ " bound was accepted"))
    [
      ( "buffer",
        O.Audio.Text_to_speech.stream_events ~max_buffer_bytes:0 inert_client
          ~api_key:(A.api_key "key") sse_request );
      ( "JSON",
        O.Audio.Text_to_speech.stream_events ~max_json_bytes:(-1) inert_client
          ~api_key:(A.api_key "key") sse_request );
      ( "pending",
        O.Audio.Text_to_speech.stream_events ~max_pending_events:0 inert_client
          ~api_key:(A.api_key "key") sse_request );
    ];
  Alcotest.(check int) "mismatches rejected before transport" 0 !calls;
  let transport =
    Eta_http.Error.make ~method_:"POST" ~uri:"speech"
      (Eta_http.Error.Connect_error { message = "offline" })
  in
  let transport_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ -> E.fail transport)
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  (match
     B.run rt
       (O.Audio.Text_to_speech.stream_audio transport_client
          ~api_key:(A.api_key "key") audio_request)
   with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Http _)) -> ()
  | _ -> Alcotest.fail "transport failure escaped nominal channel");
  let read_releases = ref 0 in
  let read_body =
    H.Body.Stream.of_reader
      ~release:(fun () -> E.sync (fun () -> incr read_releases))
      (fun () -> E.fail transport)
  in
  let read_client =
    test_client (H.Response.make ~status:200 ~body:read_body ()) (ref None)
  in
  let read_stream =
    run_ok rt "open read-failing audio"
      (O.Audio.Text_to_speech.stream_audio read_client
         ~api_key:(A.api_key "key") audio_request)
  in
  (match B.run rt (O.Audio.Text_to_speech.read_audio read_stream) with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Http _)) -> ()
  | _ -> Alcotest.fail "midstream transport failure escaped nominal channel");
  Alcotest.(check int) "midstream transport release exactly once" 1
    !read_releases;
  let defect_releases = ref 0 in
  let defect_body =
    H.Body.Stream.of_reader
      ~release:(fun () -> E.sync (fun () -> incr defect_releases))
      (fun () -> E.die_message "speech parser pull defect")
  in
  let defect_client =
    test_client (H.Response.make ~status:200 ~body:defect_body ()) (ref None)
  in
  let defect_stream =
    run_ok rt "open defecting event stream"
      (O.Audio.Text_to_speech.stream_events defect_client
         ~api_key:(A.api_key "key") sse_request)
  in
  (match B.run rt (O.Audio.Text_to_speech.read_event defect_stream) with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | _ -> Alcotest.fail "post-response pull defect escaped cleanup guard");
  Alcotest.(check int) "post-response defect release exactly once" 1
    !defect_releases;
  let headers =
    H.Core.Header.unsafe_of_list
      [ ("content-type", "application/json"); ("x-request-id", "req_speech") ]
  in
  let provider_client =
    test_client
      (response_of_bytes ~status:429 ~headers
         {|{"error":{"message":"slow down","code":"rate_limit"}}|})
      (ref None)
  in
  (match
    B.run rt
      (O.Audio.Text_to_speech.stream_audio provider_client
         ~api_key:(A.api_key "key") audio_request)
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Provider
          {
            status = 429;
            headers = preserved;
            raw_body;
            payload =
              Some
                {
                  message = Some "slow down";
                  code = Some (`String "rate_limit");
                  _;
                };
          })) ->
      Alcotest.(check (option string)) "ordered/provider header"
        (Some "req_speech")
        (H.Core.Header.get "x-request-id" preserved);
      require_contains "provider raw body" ~needle:"slow down" raw_body
  | _ -> Alcotest.fail "provider failure was not preserved");
  let large_marker = String.make (1024 * 1024 + 17) 'z' in
  let large_raw =
    Printf.sprintf
      {|{"error":{"message":"large-provider-sentinel","code":"large_error"},"padding":"%s"}|}
      large_marker
  in
  let large_releases = ref 0 in
  let large_body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr large_releases))
      [ Bytes.of_string large_raw ]
  in
  let large_headers =
    H.Core.Header.unsafe_of_list
      [
        ("x-ordered", "first");
        ("x-ordered", "second");
        ("content-type", "application/json");
      ]
  in
  let large_client =
    test_client
      (H.Response.make ~status:503 ~headers:large_headers ~body:large_body ())
      (ref None)
  in
  (match
     B.run rt
       (O.Audio.Text_to_speech.stream_audio large_client
          ~api_key:(A.api_key "key") audio_request)
   with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (O.Error.Provider
          {
            status = 503;
            headers;
            raw_body;
            payload =
              Some
                {
                  message = Some "large-provider-sentinel";
                  code = Some (`String "large_error");
                  _;
                };
          })) ->
      Alcotest.(check (list string)) "ordered duplicate headers"
        [ "first"; "second" ]
        (H.Core.Header.get_all "x-ordered" headers);
      Alcotest.(check int) "complete large raw body" (String.length large_raw)
        (String.length raw_body);
      Alcotest.(check string) "large raw body exact" large_raw raw_body
  | _ -> Alcotest.fail "large non-2xx body was not preserved");
  Alcotest.(check int) "large non-2xx release exactly once" 1 !large_releases;
  B.drain rt

let test_oaobs_speech_safe_attributes () =
  B.with_traced_runtime @@ fun ctx rt tracer ->
  let provider = O.provider ~base_url:"https://api.openai.test:8443" () in
  let api_key = A.api_key "secret-key-sentinel" in
  let client =
    test_client ~with_http_span:true
      (response_of_bytes ~headers:[ ("content-type", "audio/mpeg") ]
         "audio-bytes-sentinel")
      (ref None)
  in
  ignore
    (run_ok rt "traced speech"
       (O.Audio.Text_to_speech.create
          ~provider client ~api_key
          (speech_request ~instructions:"instruction-sentinel"
             "input-text-sentinel")));
  let open_audio body =
    let client =
      test_client (H.Response.make ~status:200 ~body ()) (ref None)
    in
    run_ok rt "open traced speech stream"
      (O.Audio.Text_to_speech.stream_audio ~provider client ~api_key
         (speech_request ~stream_format:O.Audio.Text_to_speech.Audio
            "input-text-sentinel"))
  in
  let close_stream =
    open_audio
      (H.Body.Stream.of_bytes [ Bytes.of_string "audio-close-sentinel" ])
  in
  run_ok rt "close traced speech stream"
    (O.Audio.Text_to_speech.close_audio close_stream);
  let collect_stream =
    open_audio
      (H.Body.Stream.of_bytes [ Bytes.of_string "audio-collect-sentinel" ])
  in
  ignore
    (run_ok rt "collect traced speech stream"
       (O.Audio.Text_to_speech.collect_audio ~max_bytes:64 collect_stream));
  let limit_stream =
    open_audio
      (H.Body.Stream.of_bytes [ Bytes.of_string "audio-limit-sentinel" ])
  in
  ignore
    (B.run rt
       (O.Audio.Text_to_speech.collect_audio ~max_bytes:1 limit_stream));
  let transport =
    Eta_http.Error.make ~method_:"POST" ~uri:"speech-read"
      (Eta_http.Error.Connect_error
         { message = "transport-message-sentinel" })
  in
  let http_stream =
    open_audio (H.Body.Stream.of_reader (fun () -> E.fail transport))
  in
  ignore (B.run rt (O.Audio.Text_to_speech.read_audio http_stream));
  let malformed_client =
    test_client
      (response_of_bytes
         "data: decode-fragment-sentinel\n\n")
      (ref None)
  in
  let malformed_stream =
    run_ok rt "open malformed traced SSE"
      (O.Audio.Text_to_speech.stream_events ~provider malformed_client ~api_key
         (speech_request ~stream_format:O.Audio.Text_to_speech.Sse
            "input-text-sentinel"))
  in
  ignore (B.run rt (O.Audio.Text_to_speech.read_event malformed_stream));
  let close_event_client =
    test_client
      (response_of_bytes "data: {\"type\":\"unused\"}\n\n")
      (ref None)
  in
  let close_event_stream =
    run_ok rt "open close-only traced SSE"
      (O.Audio.Text_to_speech.stream_events ~provider close_event_client ~api_key
         (speech_request ~stream_format:O.Audio.Text_to_speech.Sse
            "input-text-sentinel"))
  in
  run_ok rt "close traced SSE"
    (O.Audio.Text_to_speech.close_events close_event_stream);
  let started, started_resolver = B.create_promise () in
  let gate, _gate_resolver = B.create_promise () in
  let cancellation_releases = ref 0 in
  let blocked_body =
    H.Body.Stream.of_reader
      ~release:(fun () ->
        E.sync (fun () -> incr cancellation_releases))
      (fun () ->
        E.sync (fun () -> B.try_resolve started_resolver ())
        |> E.bind (fun () -> B.await_effect gate)
        |> E.map (fun () ->
               H.Body.Stream.Chunk
                 (Bytes.of_string "audio-cancel-sentinel")))
  in
  let blocked = open_audio blocked_body in
  let blocked_read =
    B.fork_run_cancelable ctx rt (O.Audio.Text_to_speech.read_audio blocked)
  in
  ignore (B.await started : unit);
  ignore (B.run rt (O.Audio.Text_to_speech.close_audio blocked));
  Alcotest.(check int) "concurrent telemetry operation has no release" 0
    !cancellation_releases;
  B.cancel_fiber blocked_read;
  ignore (B.await_cancelable blocked_read);
  Alcotest.(check int) "telemetry cancellation releases once" 1
    !cancellation_releases;
  let failure_client =
    test_client
      (response_of_bytes ~status:400
         {|{"error":{"message":"provider-message-sentinel","code":"bad_speech"}}|})
      (ref None)
  in
  ignore
    (B.run rt
       (O.Audio.Text_to_speech.create ~provider failure_client ~api_key
          (speech_request "input-text-sentinel")));
  let spans = Eta_observability.Tracer.dump tracer in
  let span =
    spans
    |> List.find (fun (span : Eta_observability.Tracer.span) ->
           String.equal span.name "speech.create openai"
           && span.status = Eta_observability.Tracer.Ok)
  in
  check_attr "speech operation" "speech.create" span.attrs
    "eta_ai.operation.name";
  check_attr "speech provider" "openai" span.attrs "eta_ai.provider.name";
  check_attr "speech model" "gpt-4o-mini-tts" span.attrs
    "gen_ai.request.model";
  check_attr "speech authority" "api.openai.test" span.attrs "server.address";
  let find_span name status =
    List.find
      (fun (span : Eta_observability.Tracer.span) ->
        String.equal span.name name && span.status = status)
      spans
  in
  let stream_span =
    find_span "speech.stream_audio openai" Eta_observability.Tracer.Ok
  in
  check_attr "stream mode" "audio" stream_span.attrs
    "eta_ai.request.stream_format";
  ignore (find_span "speech.stream_events openai" Eta_observability.Tracer.Ok);
  ignore (find_span "speech.close_audio openai" Eta_observability.Tracer.Ok);
  ignore (find_span "speech.close_events openai" Eta_observability.Tracer.Ok);
  ignore (find_span "speech.collect_audio openai" Eta_observability.Tracer.Ok);
  ignore
    (find_span "speech.collect_audio openai"
       (Eta_observability.Tracer.Error "limit_exceeded"));
  ignore
    (find_span "speech.read_audio openai" (Eta_observability.Tracer.Error "http_error"));
  ignore
    (find_span "speech.read_event openai"
       (Eta_observability.Tracer.Error "decode_error"));
  ignore
    (find_span "speech.close_audio openai"
       (Eta_observability.Tracer.Error "concurrent_use"));
  ignore (find_span "speech.read_audio openai" Eta_observability.Tracer.Cancelled);
  let failure_span =
    find_span "speech.create openai" (Eta_observability.Tracer.Error "bad_speech")
  in
  check_attr "speech error classification" "bad_speech" failure_span.attrs
    "error.type";
  let rendered =
    spans
    |> List.map (fun (span : Eta_observability.Tracer.span) ->
           let status =
             match span.status with
             | Eta_observability.Tracer.Ok -> "ok"
             | Cancelled -> "cancelled"
             | Error message -> "error:" ^ message
           in
           span.name ^ "\n" ^ status ^ "\n"
           ^ (span.attrs
             |> List.map (fun (key, value) -> key ^ "=" ^ value)
             |> String.concat "\n"))
    |> String.concat "\n"
  in
  List.iter
    (fun secret ->
      Alcotest.(check bool) ("telemetry excludes " ^ secret) false
        (contains ~needle:secret rendered))
    [
      "secret-key-sentinel";
      "instruction-sentinel";
      "input-text-sentinel";
      "audio-bytes-sentinel";
      "audio-close-sentinel";
      "audio-collect-sentinel";
      "audio-limit-sentinel";
      "audio-cancel-sentinel";
      "provider-message-sentinel";
      "transport-message-sentinel";
      "decode-fragment-sentinel";
    ];
  Alcotest.(check bool) "nested HTTP span suppressed" false
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "HTTP POST")
       spans)

let transcription_file ?(content_type = "audio/wav") data =
  { A.Audio.filename = "sample.wav"; content_type; source = A.Audio.bytes data }

let expect_decode_raw label raw = function
  | Error (O.Error.Decode { raw_body = Some actual; _ }) ->
      Alcotest.(check string) (label ^ " raw") raw actual
  | Error error ->
      Alcotest.failf "%s: expected Decode, got %a" label O.Error.pp error
  | Ok _ -> Alcotest.fail (label ^ ": expected Decode")

let transcription_segment_json =
  {|{"id":7,"seek":12,"start":1.25,"end":2.5,"text":" segment","tokens":[1,2,3],"temperature":0.2,"avg_logprob":-0.3,"compression_ratio":1.1,"no_speech_prob":0.01,"future":"segment-raw"}|}

let test_transcription_format_canonicalization_and_validation () =
  let open O.Audio.Speech_to_text in
  let json =
    {|{"text":"hello","usage":{"type":"duration","seconds":1.5}}|}
  in
  let verbose =
    Printf.sprintf
      {|{"text":"hello","language":"english","duration":2.5,"segments":[%s],"words":[{"word":"hello","start":0.0,"end":1.0}],"usage":{"type":"duration","seconds":3.0}}|}
      transcription_segment_json
  in
  let diarized =
    {|{"text":"hello","duration":2.0,"task":"transcribe","segments":[{"id":"seg_1","speaker":"A","start":0.0,"end":2.0,"text":"hello","type":"transcript.text.segment"}],"usage":{"type":"duration","seconds":2.0}}|}
  in
  let cases =
    [
      (Json, "json", json);
      (Text, "text", "plain text");
      (Srt, "srt", "1\n00:00:00,000 --> 00:00:01,000\nhello");
      (Verbose_json, "verbose_json", verbose);
      (Vtt, "vtt", "WEBVTT\n\nhello");
      (Diarized_json, "diarized_json", diarized);
    ]
  in
  List.iter
    (fun (named, wire, body) ->
      let named = decode_response (Some named) body in
      let other = decode_response (Some (Other_format wire)) body in
      Alcotest.(check bool)
        ("named/Other decode equivalence " ^ wire)
        true (named = other))
    cases;
  (match decode_response (Some (Other_format "future_format")) "opaque" with
  | Ok (Other_result { format = "future_format"; body = "opaque" }) -> ()
  | _ -> Alcotest.fail "unknown transcription format was not preserved");
  let file = transcription_file (Bytes.of_string "RIFF") in
  let accepted model format =
    match request ~model ~file ~response_format:format () with
    | Ok _ -> true
    | Error _ -> false
  in
  let whisper_formats = [ Json; Text; Srt; Verbose_json; Vtt ] in
  List.iter
    (fun named ->
      let wire = response_format_to_string named in
      Alcotest.(check bool)
        ("whisper named format accepted " ^ wire)
        true (accepted Whisper_1 named);
      Alcotest.(check bool)
        ("whisper Other format accepted " ^ wire)
        true (accepted Whisper_1 (Other_format wire)))
    whisper_formats;
  Alcotest.(check bool) "whisper named diarized rejected" false
    (accepted Whisper_1 Diarized_json);
  Alcotest.(check bool) "whisper Other diarized rejected" false
    (accepted Whisper_1 (Other_format "diarized_json"));
  List.iter
    (fun (named, wire) ->
      Alcotest.(check bool)
        ("gpt format restriction named " ^ wire)
        false (accepted Gpt_4o_transcribe named);
      Alcotest.(check bool)
        ("gpt format restriction Other " ^ wire)
        false (accepted Gpt_4o_transcribe (Other_format wire)))
    [
      (Text, "text");
      (Srt, "srt");
      (Verbose_json, "verbose_json");
      (Vtt, "vtt");
      (Diarized_json, "diarized_json");
    ];
  let timestamp_named =
    request ~model:Whisper_1 ~file ~response_format:Verbose_json
      ~timestamp_granularities:[ Word ] ()
  in
  let timestamp_other =
    request ~model:Whisper_1 ~file
      ~response_format:(Other_format "verbose_json")
      ~timestamp_granularities:[ Word ] ()
  in
  Alcotest.(check bool) "timestamp named/Other accepted" true
    (Result.is_ok timestamp_named && Result.is_ok timestamp_other);
  let bypass =
    request ~model:Whisper_1 ~file
      ~response_format:(Other_format "json")
      ~timestamp_granularities:[ Word ] ()
  in
  ignore (expect_invalid_request "Other json timestamp bypass" bypass)

let test_transcription_buffered_result_matrix () =
  let open O.Audio.Speech_to_text in
  let json_raw =
    {|{"text":"hello","languages":[{"code":"en","future":"language"}],"logprobs":[{"token":"h","bytes":[104],"logprob":-0.25,"future":"logprob"}],"usage":{"type":"tokens","input_tokens":3,"output_tokens":2,"total_tokens":5,"input_token_details":{"audio_tokens":3,"text_tokens":0,"future":"input-details"},"output_token_details":{"audio_tokens":0,"text_tokens":2,"future":"output-details"},"future":"usage"},"future":"top"}|}
  in
  (match decode_response (Some Json) json_raw with
  | Ok
      (Json_result
        {
          text = "hello";
          languages = Some [ { code = "en"; raw = language_raw } ];
          logprobs =
            Some
              [
                {
                  token = Some "h";
                  bytes = Some [ 104 ];
                  logprob = Some probability;
                  raw = logprob_raw;
                };
              ];
          usage =
            Some
              (Tokens
                {
                  input_tokens = 3;
                  output_tokens = 2;
                  total_tokens = 5;
                  input_token_details =
                    Some { audio_tokens = Some 3; text_tokens = Some 0; _ };
                  output_token_details =
                    Some { audio_tokens = Some 0; text_tokens = Some 2; _ };
                  raw = usage_raw;
                });
          raw;
        }) ->
      Alcotest.(check (float 0.0001)) "log probability" (-0.25) probability;
      Alcotest.(check bool) "language raw complete" true
        (Option.is_some (A.Json.string_member "future" language_raw));
      Alcotest.(check bool) "logprob raw complete" true
        (Option.is_some (A.Json.string_member "future" logprob_raw));
      Alcotest.(check bool) "usage raw complete" true
        (Option.is_some (A.Json.string_member "future" usage_raw));
      Alcotest.(check bool) "top raw complete" true
        (Option.is_some (A.Json.string_member "future" raw))
  | _ -> Alcotest.fail "complete JSON transcription did not decode");
  let duration_raw =
    {|{"text":"duration","usage":{"type":"duration","seconds":4.5}}|}
  in
  (match decode_response (Some Json) duration_raw with
  | Ok
      (Json_result
        { usage = Some (Duration { seconds = 4.5; _ }); _ }) ->
      ()
  | _ -> Alcotest.fail "JSON duration usage did not decode");
  let verbose_raw =
    Printf.sprintf
      {|{"text":"hello","language":"english","duration":2.5,"segments":[%s],"words":[{"word":"hello","start":0.0,"end":1.0,"future":"word"}],"usage":{"type":"duration","seconds":3.0},"future":"verbose"}|}
      transcription_segment_json
  in
  (match decode_response (Some Verbose_json) verbose_raw with
  | Ok
      (Verbose_json_result
        {
          text = "hello";
          language = "english";
          duration = 2.5;
          segments = Some [ segment ];
          words = Some [ word ];
          usage = Some (Duration { seconds = 3.0; _ });
          raw;
        }) ->
      Alcotest.(check int) "segment id" 7 segment.id;
      Alcotest.(check int) "segment seek" 12 segment.seek;
      Alcotest.(check (list int)) "segment tokens" [ 1; 2; 3 ]
        segment.tokens;
      Alcotest.(check string) "word" "hello" word.word;
      Alcotest.(check bool) "verbose raw complete" true
        (Option.is_some (A.Json.string_member "future" raw))
  | _ -> Alcotest.fail "complete verbose transcription did not decode");
  let diarized_raw =
    {|{"text":"hello","duration":2.0,"task":"transcribe","segments":[{"id":"seg_1","speaker":"agent","start":0.0,"end":2.0,"text":"hello","type":"transcript.text.segment","future":"segment"}],"usage":{"type":"tokens","input_tokens":2,"output_tokens":1,"total_tokens":3},"future":"diarized"}|}
  in
  (match decode_response (Some Diarized_json) diarized_raw with
  | Ok
      (Diarized_json_result
        {
          text = "hello";
          duration = 2.0;
          task = "transcribe";
          segments = [ segment ];
          usage = Some (Tokens { total_tokens = 3; _ });
          raw;
        }) ->
      Alcotest.(check string) "speaker" "agent" segment.speaker;
      Alcotest.(check bool) "diarized segment raw complete" true
        (Option.is_some (A.Json.string_member "future" segment.raw));
      Alcotest.(check bool) "diarized raw complete" true
        (Option.is_some (A.Json.string_member "future" raw))
  | _ -> Alcotest.fail "complete diarized transcription did not decode");
  (match decode_response (Some Text) "plain" with
  | Ok (Text_result "plain") -> ()
  | _ -> Alcotest.fail "text result");
  (match decode_response (Some Srt) "subtitle" with
  | Ok (Srt_result "subtitle") -> ()
  | _ -> Alcotest.fail "SRT result");
  (match decode_response (Some Vtt) "captions" with
  | Ok (Vtt_result "captions") -> ()
  | _ -> Alcotest.fail "VTT result");
  (match decode_response (Some (Other_format "future")) "opaque" with
  | Ok (Other_result { format = "future"; body = "opaque" }) -> ()
  | _ -> Alcotest.fail "unknown result");
  let huge = String.make 400 '9' in
  let malformed =
    [
      ("json missing text", Json, {|{"usage":{"type":"duration","seconds":1}}|});
      ("json languages shape", Json, {|{"text":"x","languages":{}}|});
      ("json logprob finite", Json, {|{"text":"x","logprobs":[{"logprob":1e999}]}|});
      ("json usage missing discriminator", Json,
       {|{"text":"x","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}|});
      ("json usage null", Json, {|{"text":"x","usage":null}|});
      ("json token usage missing total", Json,
       {|{"text":"x","usage":{"type":"tokens","input_tokens":1,"output_tokens":1}}|});
      ("json token details shape", Json,
       {|{"text":"x","usage":{"type":"tokens","input_tokens":1,"output_tokens":1,"total_tokens":2,"input_token_details":[]}}|});
      ("json token details null", Json,
       {|{"text":"x","usage":{"type":"tokens","input_tokens":1,"output_tokens":1,"total_tokens":2,"input_token_details":null}}|});
      ("json token detail numeric", Json,
       {|{"text":"x","usage":{"type":"tokens","input_tokens":1,"output_tokens":1,"total_tokens":2,"input_token_details":{"audio_tokens":1.5}}}|});
      ("verbose token usage", Verbose_json,
       {|{"text":"x","language":"en","duration":1,"usage":{"type":"tokens","input_tokens":1,"output_tokens":1,"total_tokens":2}}|});
      ("verbose huge duration", Verbose_json,
       Printf.sprintf {|{"text":"x","language":"en","duration":%s}|} huge);
      ("diarized segment type", Diarized_json,
       {|{"text":"x","duration":1,"task":"transcribe","segments":[{"id":"s","speaker":"A","start":0,"end":1,"text":"x","type":"wrong"}]}|});
      ("diarized missing segments", Diarized_json,
       {|{"text":"x","duration":1,"task":"transcribe"}|});
    ]
  in
  List.iter
    (fun (label, format, raw) ->
      expect_decode_raw label raw (decode_response (Some format) raw))
    malformed

let test_translation_result_and_malformed_matrix () =
  let open O.Audio.Translation in
  let verbose =
    Printf.sprintf
      {|{"language":"english","duration":2.5,"text":"hello","segments":[%s],"future":"translation"}|}
      transcription_segment_json
  in
  let cases =
    [
      (Json, "json", {|{"text":"hello","future":"json"}|});
      (Text, "text", "plain");
      (Srt, "srt", "subtitle");
      (Verbose_json, "verbose_json", verbose);
      (Vtt, "vtt", "captions");
    ]
  in
  List.iter
    (fun (named, wire, raw) ->
      Alcotest.(check bool)
        ("translation named/Other " ^ wire)
        true
        (decode_response (Some named) raw
        = decode_response (Some (Other_format wire)) raw))
    cases;
  let file = transcription_file (Bytes.of_string "RIFF") in
  List.iter
    (fun (named, wire, _) ->
      Alcotest.(check bool)
        ("translation request named/Other " ^ wire)
        true
        (Result.is_ok (request ~file ~response_format:named ())
        && Result.is_ok
             (request ~file ~response_format:(Other_format wire) ())))
    cases;
  request ~file ~response_format:(Other_format "") ()
  |> expect_invalid_request "blank translation response format"
  |> ignore;
  (match decode_response (Some Json) {|{"text":"hello","future":"json"}|} with
  | Ok (Json_result { text = "hello"; raw }) ->
      Alcotest.(check bool) "translation JSON raw" true
        (Option.is_some (A.Json.string_member "future" raw))
  | _ -> Alcotest.fail "translation JSON result");
  (match decode_response (Some Verbose_json) verbose with
  | Ok
      (Verbose_json_result
        {
          language = "english";
          duration = 2.5;
          text = "hello";
          segments = Some [ segment ];
          raw;
        }) ->
      Alcotest.(check int) "translation segment id" 7 segment.id;
      Alcotest.(check bool) "translation segment raw" true
        (Option.is_some (A.Json.string_member "future" segment.raw));
      Alcotest.(check bool) "translation verbose raw" true
        (Option.is_some (A.Json.string_member "future" raw))
  | _ -> Alcotest.fail "translation verbose result");
  (match decode_response (Some (Other_format "future")) "opaque" with
  | Ok (Other_result { format = "future"; body = "opaque" }) -> ()
  | _ -> Alcotest.fail "translation unknown result");
  let huge = String.make 400 '9' in
  let malformed =
    [
      ("translation missing text", Json, "{}");
      ("translation wrong text", Json, {|{"text":1}|});
      ("translation non-English", Verbose_json,
       {|{"language":"french","duration":1,"text":"x"}|});
      ("translation bad segments", Verbose_json,
       {|{"language":"english","duration":1,"text":"x","segments":{}}|});
      ("translation bad segment", Verbose_json,
       {|{"language":"english","duration":1,"text":"x","segments":[{"id":1}]}|});
      ("translation huge duration", Verbose_json,
       Printf.sprintf
         {|{"language":"english","duration":%s,"text":"x"}|} huge);
    ]
  in
  List.iter
    (fun (label, format, raw) ->
      expect_decode_raw label raw (decode_response (Some format) raw))
    malformed

let test_transcription_request_and_decode () =
  let transcription =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe
      ~file:(transcription_file (Bytes.of_string "RIFF")) ~language:"en"
      ~response_format:O.Audio.Speech_to_text.Json ~temperature:0.0 ()
    |> expect_ok "transcription constructor"
  in
  let request =
    O.Audio.Speech_to_text.http_request ~api_key:(A.api_key "sk-test") transcription
    |> expect_ok "transcription request"
  in
  Alcotest.(check string) "uri" "https://api.openai.com/v1/audio/transcriptions" request.uri;
  Alcotest.(check bool) "multipart" true
    (Option.is_some (H.Core.Header.get "content-type" request.headers));
  match O.Audio.Speech_to_text.decode_response (Some O.Audio.Speech_to_text.Json)
          (read_fixture "transcription.json") |> expect_ok "transcription fixture" with
  | O.Audio.Speech_to_text.Json_result result ->
      Alcotest.(check string) "text" "hello eta" result.text
  | _ -> Alcotest.fail "expected JSON transcription"

let test_transcription_request_rejects_multipart_header_injection () =
  let make ?(content_type = "audio/wav") ?(extra_fields = []) () =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe
      ~file:(transcription_file ~content_type (Bytes.of_string "RIFF"))
      ~extra_fields ()
  in
  let field_error =
    make ~extra_fields:[ ("bad\r\nname", "value") ] ()
    |> expect_invalid_request "transcription extra field name"
  in
  require_contains "field name error" ~needle:"field name" field_error;
  let content_type_error =
    make ~content_type:"audio/wav\r\nX-Injected: yes" ()
    |> expect_invalid_request "transcription content type"
  in
  require_contains "content type error" ~needle:"content type" content_type_error

let test_transcription_request_avoids_boundary_collision () =
  let transcription =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe
      ~file:(transcription_file (Bytes.of_string "RIFF"))
      ~prompt:"please transcribe" () |> expect_ok "transcription constructor"
  in
  let request = O.Audio.Speech_to_text.http_request ~api_key:(A.api_key "sk-test") transcription
    |> expect_ok "transcription request" in
  let boundary = multipart_boundary request in
  Alcotest.(check bool) "nonempty boundary" true (String.length boundary > 20)

let test_transcription_chunking_speakers_repetition_and_size () =
  with_runtime @@ fun rt ->
  let request_body request =
    H.Request.body_source request.H.Request.body |> H.Body.Source.to_stream
    |> H.Body.Stream.read_all ~max_bytes:200_000
    |> run_ok rt "multipart body" |> Bytes.to_string
  in
  let find_from body start needle =
    let rec loop index =
      if index + String.length needle > String.length body then None
      else if String.sub body index (String.length needle) = needle then
        Some index
      else loop (index + 1)
    in
    loop start
  in
  let assert_repeated_order body name values =
    let field_marker = "name=\"" ^ name ^ "\"" in
    let rec count_markers start count =
      match find_from body start field_marker with
      | None -> count
      | Some index ->
          count_markers (index + String.length field_marker) (count + 1)
    in
    let _, count =
      List.fold_left
        (fun (start, count) value ->
          let needle =
            "name=\"" ^ name ^ "\"\r\n\r\n" ^ value ^ "\r\n"
          in
          match find_from body start needle with
          | Some index -> (index + String.length needle, count + 1)
          | None ->
              Alcotest.failf "missing ordered multipart %s value %S" name value)
        (0, 0) values
    in
    Alcotest.(check int) (name ^ " exact repetitions")
      (List.length values) count;
    Alcotest.(check int) (name ^ " no additional repetitions")
      (List.length values) (count_markers 0 0)
  in
  let open O.Audio.Speech_to_text in
  let ordinary_file = transcription_file (Bytes.of_string "RIFF") in
  let context_request =
    request ~model:Gpt_transcribe ~file:ordinary_file
      ~keywords:[ "keyword-one"; "keyword-two" ]
      ~languages:[ "en"; "fr" ] ~chunking_strategy:Auto ()
    |> expect_ok "context/chunking request"
    |> http_request ~api_key:(A.api_key "key")
    |> expect_ok "context/chunking HTTP request"
  in
  let context_body = request_body context_request in
  assert_repeated_order context_body "keywords[]"
    [ "keyword-one"; "keyword-two" ];
  assert_repeated_order context_body "languages[]" [ "en"; "fr" ];
  require_contains "chunking is not diarization-only"
    ~needle:"name=\"chunking_strategy\"\r\n\r\nauto\r\n" context_body;
  let timestamp_request =
    request ~model:Whisper_1 ~file:ordinary_file
      ~response_format:Verbose_json
      ~timestamp_granularities:[ Word; Segment ] ()
    |> expect_ok "timestamp request"
    |> http_request ~api_key:(A.api_key "key")
    |> expect_ok "timestamp HTTP request"
  in
  assert_repeated_order (request_body timestamp_request)
    "timestamp_granularities[]" [ "word"; "segment" ];
  let references =
    [ "data:audio/wav;base64,QUFB"; "data:audio/mpeg;base64,QkJC" ]
  in
  let speaker_request =
    request ~model:Gpt_4o_transcribe_diarize ~file:ordinary_file
      ~response_format:Diarized_json
      ~known_speaker_names:[ "agent"; "customer" ]
      ~known_speaker_references:references ()
    |> expect_ok "speaker request"
    |> http_request ~api_key:(A.api_key "key")
    |> expect_ok "speaker HTTP request"
  in
  let speaker_body = request_body speaker_request in
  assert_repeated_order speaker_body "known_speaker_names[]"
    [ "agent"; "customer" ];
  assert_repeated_order speaker_body "known_speaker_references[]" references;
  List.iter
    (fun subtype ->
      request ~model:Gpt_4o_transcribe_diarize ~file:ordinary_file
        ~response_format:Diarized_json ~known_speaker_names:[ "agent" ]
        ~known_speaker_references:
          [ "data:audio/" ^ subtype ^ ";base64,QUFB" ]
        ()
      |> expect_ok ("valid speaker subtype " ^ subtype)
      |> ignore)
    [ "mpeg"; "mp4"; "wav"; "webm" ];
  List.iter
    (fun payload ->
      request ~model:Gpt_4o_transcribe_diarize ~file:ordinary_file
        ~response_format:Diarized_json ~known_speaker_names:[ "agent" ]
        ~known_speaker_references:
          [ "data:audio/wav;base64," ^ payload ]
        ()
      |> expect_ok ("valid speaker base64 " ^ payload)
      |> ignore)
    [ "QQ=="; "+/8=" ];
  let valid_vad =
    `Assoc
      [
        ("type", `String "server_vad");
        ("prefix_padding_ms", `Int 100);
        ("silence_duration_ms", `Int 500);
        ("threshold", `Float 0.4);
        ("future", `String "preserved");
      ]
  in
  ignore
    (request ~model:Gpt_4o_transcribe ~file:ordinary_file
       ~chunking_strategy:
         (Server_vad
            {
              prefix_padding_ms = Some 100;
              silence_duration_ms = Some 500;
              threshold = Some 0.4;
            })
       ()
    |> expect_ok "typed server_vad");
  ignore
    (request ~model:Gpt_4o_transcribe ~file:ordinary_file
       ~chunking_strategy:(Other_chunking (`String "auto")) ()
    |> expect_ok "Other auto");
  ignore
    (request ~model:Gpt_4o_transcribe ~file:ordinary_file
       ~chunking_strategy:(Other_chunking valid_vad) ()
    |> expect_ok "Other server_vad");
  ignore
    (request ~model:Gpt_4o_transcribe ~file:ordinary_file
       ~chunking_strategy:
         (Other_chunking
            (`Assoc
              [
                ("type", `String "future_vad");
                ("future", `String "value");
              ]))
       ()
    |> expect_ok "future chunking strategy");
  let invalid_chunking =
    [
      Server_vad
        {
          prefix_padding_ms = None;
          silence_duration_ms = None;
          threshold = Some infinity;
        };
      Other_chunking
        (`Assoc
          [
            ("type", `String "server_vad");
            ("threshold", `Float nan);
          ]);
      Other_chunking
        (`Assoc
          [
            ("type", `String "server_vad");
            ("prefix_padding_ms", `Int (-1));
          ]);
      Other_chunking
        (`Assoc
          [
            ("type", `String "server_vad");
            ("silence_duration_ms", `String "500");
          ]);
      Other_chunking
        (`Assoc
          [
            ("type", `String "server_vad");
            ("threshold", `Intlit (String.make 400 '9'));
          ]);
      Other_chunking (`String "server_vad");
      Other_chunking (`Assoc [ ("type", `String "auto") ]);
    ]
  in
  List.iteri
    (fun index chunking_strategy ->
      request ~model:Gpt_4o_transcribe ~file:ordinary_file ~chunking_strategy ()
      |> expect_invalid_request
           (Printf.sprintf "invalid canonical chunking %d" index)
      |> ignore)
    invalid_chunking;
  List.iter
    (fun reference ->
      request ~model:Gpt_4o_transcribe_diarize ~file:ordinary_file
        ~response_format:Diarized_json ~known_speaker_names:[ "agent" ]
        ~known_speaker_references:[ reference ] ()
      |> expect_invalid_request ("invalid speaker reference " ^ reference)
      |> ignore)
    [
      "https://example.test/audio.wav";
      "data:text/plain;base64,QUFB";
      "data:audio/wav,QUFB";
      "data:audio/wav;base64,";
      "data:audio/wav;base64,%%%";
      "data:audio/wav\r\n;base64,QUFB";
      "data:audio/mp3;base64,QUFB";
      "data:audio/m4a;base64,QUFB";
      "data:audio/x-wav;base64,QUFB";
      "data:audio/x-m4a;base64,QUFB";
      "data:audio/ogg;base64,QUFB";
      "data:audio/future;base64,QUFB";
      "data:audio/wav;name=clip;base64,QUFB";
      "data:audio/wav,extra;base64,QUFB";
      "data:audio/wav;base64;base64,QUFB";
      "data:audio/wav;base64,QUFB,";
      "data:audio/wav;base64,QU FB";
      "data:audio/wav;base64,QU=F";
      "data:audio/wav;base64,QUFB====";
    ];
  let sized_source length =
    A.Audio.stream ~length ~replayability:A.Audio.Replayable (fun () ->
        fun () -> None)
  in
  let sized_file length =
    {
      A.Audio.filename = "sized.wav";
      content_type = "audio/wav";
      source = sized_source length;
    }
  in
  ignore
    (request ~model:Gpt_4o_transcribe
       ~file:(sized_file 26_214_400L) ()
    |> expect_ok "transcription exact 25 MiB");
  let transcription_limit =
    request ~model:Gpt_4o_transcribe ~file:(sized_file 26_214_401L) ()
    |> expect_invalid_request "transcription one over 25 MB"
  in
  Alcotest.(check string) "transcription documented upload limit"
    "transcription upload exceeds the documented 25 MB (26,214,400 bytes) maximum"
    transcription_limit;
  ignore
    (O.Audio.Translation.request ~file:(sized_file 26_214_400L) ()
    |> expect_ok "translation exact 25 MiB");
  let translation_limit =
    O.Audio.Translation.request ~file:(sized_file 26_214_401L) ()
    |> expect_invalid_request "translation one over 25 MB"
  in
  Alcotest.(check string) "translation documented upload limit"
    "translation upload exceeds the documented 25 MB (26,214,400 bytes) maximum"
    translation_limit

let test_transcription_streaming_multipart_and_translation () =
  with_runtime @@ fun rt ->
  let opens = ref 0 in
  let source =
    A.Audio.stream ~length:6L ~replayability:A.Audio.Replayable (fun () ->
        incr opens;
        let chunks = ref [ Bytes.of_string "a"; Bytes.empty; Bytes.of_string "bc";
                           Bytes.of_string "def" ] in
        fun () ->
          match !chunks with
          | [] -> None
          | chunk :: rest ->
              chunks := rest;
              Some chunk)
  in
  let file = { A.Audio.filename = "audio.wav"; content_type = "audio/wav"; source } in
  let transcription =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_transcribe ~file
      ~keywords:[ "first"; "second" ] ~languages:[ "en"; "fr" ]
      ~extra_fields:[ ("future", "value") ] ()
    |> expect_ok "streaming multipart constructor"
  in
  let request =
    O.Audio.Speech_to_text.http_request ~api_key:(A.api_key "sk") transcription
    |> expect_ok "streaming multipart request"
  in
  Alcotest.(check int) "request construction does not open upload" 0 !opens;
  Alcotest.(check (option string)) "multipart removes inherited Accept" None
    (H.Core.Header.get "accept" request.headers);
  let read_body () =
    H.Request.body_source request.body |> H.Body.Source.to_stream
    |> H.Body.Stream.read_all ~max_bytes:100_000
    |> run_ok rt "read streaming multipart" |> Bytes.to_string
  in
  let body = read_body () in
  Alcotest.(check int) "first upload opening" 1 !opens;
  require_contains "multipart preserves upload bytes"
    ~needle:"\r\n\r\nabcdef\r\n--" body;
  let find_from start needle =
    let rec loop index =
      if index + String.length needle > String.length body then None
      else if String.sub body index (String.length needle) = needle then Some index
      else loop (index + 1)
    in
    loop start
  in
  let first =
    match find_from 0 "\r\n\r\nfirst\r\n" with
    | Some index -> index
    | None -> Alcotest.fail "missing first repeated field"
  in
  let second =
    match find_from (first + 1) "\r\n\r\nsecond\r\n" with
    | Some index -> index
    | None -> Alcotest.fail "missing second repeated field"
  in
  Alcotest.(check bool) "repeated caller order" true (first < second);
  Alcotest.(check (option string)) "provider leaves Content-Length to transport"
    None
    (H.Core.Header.get "content-length" request.headers);
  let body_again = read_body () in
  Alcotest.(check int) "replayable upload reopens" 2 !opens;
  Alcotest.(check string) "replayed multipart is exact" body body_again;
  let translation =
    O.Audio.Translation.request ~file
      ~response_format:O.Audio.Translation.Verbose_json ()
    |> expect_ok "translation constructor"
  in
  let translation_request =
    O.Audio.Translation.http_request ~api_key:(A.api_key "sk") translation
    |> expect_ok "translation HTTP request"
  in
  Alcotest.(check string) "translation endpoint"
    "https://api.openai.com/v1/audio/translations" translation_request.uri;
  Alcotest.(check (option string))
    "translation leaves Content-Length to transport" None
    (H.Core.Header.get "content-length" translation_request.headers);
  (match
     O.Audio.Translation.decode_response
       (Some O.Audio.Translation.Verbose_json)
       {|{"language":"english","duration":1.5,"text":"hello","segments":[]}|}
   with
  | Ok (O.Audio.Translation.Verbose_json_result result) ->
      Alcotest.(check string) "translated English text" "hello" result.text
  | Ok _ | Error _ -> Alcotest.fail "expected verbose translation")

let test_transcription_stream_events_typed_and_released () =
  with_runtime @@ fun rt ->
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr releases))
      [
        Bytes.of_string
          "data: {\"type\":\"transcript.text.delta\",\"delta\":\"hi\",\"segment_id\":\"s1\",\"logprobs\":[{\"token\":\"hi\",\"bytes\":[104,105],\"logprob\":-0.1}],\"future\":\"delta\"}\r\n\r\n";
        Bytes.of_string
          "data: {\"type\":\"transcript.text.segment\",\"id\":\"seg_1\",\"speaker\":\"agent\",\"start\":0.0,\"end\":1.0,\"text\":\"hi\",\"future\":\"segment\"}\r\r";
        Bytes.of_string
          "data: {\"type\":\"transcript.text.done\",\"text\":\"hi\",\"logprobs\":[{\"token\":\"hi\",\"bytes\":[104,105],\"logprob\":-0.1}],\"languages\":[{\"code\":\"en\"}],\"usage\":{\"type\":\"tokens\",\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3,\"input_token_details\":{\"audio_tokens\":2,\"text_tokens\":0}},\"future\":\"done\"}\n\n";
        Bytes.of_string
          "data: {\"type\":\"future.transcript\",\"nested\":{\"x\":1}}\n\n";
      ]
  in
  let client =
    test_client (H.Response.make ~status:200 ~body ()) (ref None)
  in
  let file = transcription_file (Bytes.of_string "RIFF") in
  let request =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_transcribe ~file ~stream:true ()
    |> expect_ok "stream request"
  in
  let operation =
    O.Audio.Speech_to_text.stream_events client ~api_key:(A.api_key "sk") request
    |> E.bind (fun stream ->
           let rec loop acc =
             O.Audio.Speech_to_text.read_event stream
             |> E.bind (function
                  | None -> E.pure (List.rev acc)
                  | Some event -> loop (event :: acc))
           in
           loop [])
  in
  let events = run_ok rt "typed transcription SSE" operation in
  Alcotest.(check int) "four events" 4 (List.length events);
  (match events with
  | O.Audio.Speech_to_text.Text_delta {
      delta = "hi";
      segment_id = Some "s1";
      logprobs =
        Some
          [
            {
              token = Some "hi";
              bytes = Some [ 104; 105 ];
              logprob = Some delta_logprob;
              _;
            };
          ];
      raw = delta_raw;
    }
    :: O.Audio.Speech_to_text.Text_segment segment
    :: O.Audio.Speech_to_text.Text_done {
         text = "hi";
         languages = Some [ language ];
         logprobs = Some [ _ ];
         usage =
           Some
             (O.Audio.Speech_to_text.Tokens
               {
                 input_tokens = 2;
                 output_tokens = 1;
                 total_tokens = 3;
                 input_token_details =
                   Some
                     {
                       audio_tokens = Some 2;
                       text_tokens = Some 0;
                       _;
                     };
                 _;
               });
         raw = done_raw;
       }
    :: O.Audio.Speech_to_text.Unknown { type_ = "future.transcript"; raw }
    :: [] ->
      Alcotest.(check (float 0.0001)) "delta logprob" (-0.1) delta_logprob;
      Alcotest.(check bool) "delta raw complete" true
        (Option.is_some (A.Json.string_member "future" delta_raw));
      Alcotest.(check string) "segment ID" "seg_1" segment.id;
      Alcotest.(check string) "segment speaker" "agent" segment.speaker;
      Alcotest.(check bool) "segment raw complete" true
        (Option.is_some (A.Json.string_member "future" segment.raw));
      Alcotest.(check string) "detected language" "en" language.code;
      Alcotest.(check bool) "done raw complete" true
        (Option.is_some (A.Json.string_member "future" done_raw));
      Alcotest.(check bool) "unknown complete JSON" true
        (Option.is_some (A.Json.object_member "nested" raw))
  | _ -> Alcotest.fail "unexpected transcription SSE event sequence");
  Alcotest.(check int) "response released once" 1 !releases;
  let malformed =
    [
      "{bad";
      {|{"type":"transcript.text.delta"}|};
      {|{"type":"transcript.text.segment","id":1,"speaker":"A","start":0,"end":1,"text":"x"}|};
      {|{"type":"transcript.text.done","text":"x","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}|};
      {|{"type":"transcript.text.done","text":"x","usage":{"type":"duration","seconds":1}}|};
      {|{"type":"transcript.text.done","text":"x","logprobs":[{"logprob":1e999}]}|};
    ]
  in
  List.iteri
    (fun index raw ->
      let releases = ref 0 in
      let framed = "data: " ^ raw ^ "\n\n" in
      let body =
        H.Body.Stream.of_bytes
          ~release:(fun () -> E.sync (fun () -> incr releases))
          [ Bytes.of_string framed ]
      in
      let client =
        test_client (H.Response.make ~status:200 ~body ()) (ref None)
      in
      let request =
        O.Audio.Speech_to_text.request
          ~model:O.Audio.Speech_to_text.Gpt_transcribe
          ~file:(transcription_file (Bytes.of_string "RIFF")) ~stream:true ()
        |> expect_ok "malformed stream request"
      in
      (match
         B.run rt
           (O.Audio.Speech_to_text.stream_events client
              ~api_key:(A.api_key "sk") request
           |> E.bind O.Audio.Speech_to_text.read_event)
       with
      | Eta.Exit.Error
          (Eta.Cause.Fail
            (O.Error.Decode { raw_body = Some actual; _ })) ->
          Alcotest.(check string)
            (Printf.sprintf "malformed event raw %d" index)
            raw actual
      | _ ->
          Alcotest.failf "malformed event %d did not fail Decode" index);
      Alcotest.(check int)
        (Printf.sprintf "malformed event release %d" index)
        1 !releases)
    malformed;
  let diarized_file = transcription_file (Bytes.of_string "RIFF") in
  let named =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe_diarize
      ~file:diarized_file
      ~response_format:O.Audio.Speech_to_text.Diarized_json ~stream:true ()
  in
  let other =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe_diarize
      ~file:diarized_file
      ~response_format:
        (O.Audio.Speech_to_text.Other_format "diarized_json")
      ~stream:true ()
  in
  Alcotest.(check bool) "stream named/Other diarized routing" true
    (Result.is_ok named && Result.is_ok other)

let test_transcription_translation_wrapper_failures_and_large_errors () =
  B.with_runtime @@ fun ctx rt ->
  let file = transcription_file (Bytes.of_string "audio-wrapper-sentinel") in
  let transcription =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe ~file ()
    |> expect_ok "wrapper transcription"
  in
  let translation =
    O.Audio.Translation.request ~file ()
    |> expect_ok "wrapper translation"
  in
  let transport =
    H.Error.make ~method_:"POST" ~uri:"wrapper-transport"
      (H.Error.Connect_error { message = "wrapper-transport-sentinel" })
  in
  let transport_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ -> E.fail transport)
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let expect_http label outcome =
    match outcome with
    | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Http _)) -> ()
    | _ -> Alcotest.fail (label ^ " did not map transport failure")
  in
  expect_http "transcription"
    (B.run rt
       (O.Audio.Speech_to_text.create transport_client
          ~api_key:(A.api_key "key") transcription));
  expect_http "translation"
    (B.run rt
       (O.Audio.Translation.create transport_client
          ~api_key:(A.api_key "key") translation));
  let large_padding = String.make (1024 * 1024 + 33) 'x' in
  let large_raw =
    Printf.sprintf
      {|{"error":{"message":"wrapper-large-provider","code":"wrapper_large"},"padding":"%s"}|}
      large_padding
  in
  let run_large label run =
    let releases = ref 0 in
    let body =
      H.Body.Stream.of_bytes
        ~release:(fun () -> E.sync (fun () -> incr releases))
        [ Bytes.of_string large_raw ]
    in
    let headers =
      H.Core.Header.unsafe_of_list
        [
          ("x-ordered", "first");
          ("x-ordered", "second");
          ("content-type", "application/json");
        ]
    in
    let client =
      test_client
        (H.Response.make ~status:503 ~headers ~body ())
        (ref None)
    in
    (match B.run rt (run client) with
    | Eta.Exit.Error
        (Eta.Cause.Fail
          (O.Error.Provider
            {
              status = 503;
              headers;
              raw_body;
              payload =
                Some
                  {
                    message = Some "wrapper-large-provider";
                    code = Some (`String "wrapper_large");
                    _;
                  };
            })) ->
        Alcotest.(check string) (label ^ " large raw exact")
          large_raw raw_body;
        Alcotest.(check (list string)) (label ^ " ordered headers")
          [ "first"; "second" ]
          (H.Core.Header.get_all "x-ordered" headers)
    | _ -> Alcotest.fail (label ^ " large provider error not preserved"));
    Alcotest.(check int) (label ^ " large response release") 1 !releases
  in
  run_large "transcription" (fun client ->
      O.Audio.Speech_to_text.create client ~api_key:(A.api_key "key")
        transcription);
  run_large "translation" (fun client ->
      O.Audio.Translation.create client ~api_key:(A.api_key "key")
        translation);
  let started, started_resolver = B.create_promise () in
  let gate, _gate_resolver = B.create_promise () in
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_reader
      ~release:(fun () -> E.sync (fun () -> incr releases))
      (fun () ->
        E.sync (fun () -> B.try_resolve started_resolver ())
        |> E.bind (fun () -> B.await_effect gate)
        |> E.map (fun () -> H.Body.Stream.End))
  in
  let stream_client =
    test_client (H.Response.make ~status:200 ~body ()) (ref None)
  in
  let stream_request =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_transcribe ~file ~stream:true ()
    |> expect_ok "cancellable transcription stream"
  in
  let stream =
    run_ok rt "open cancellable transcription stream"
      (O.Audio.Speech_to_text.stream_events stream_client
         ~api_key:(A.api_key "key") stream_request)
  in
  let reading =
    B.fork_run_cancelable ctx rt
      (O.Audio.Speech_to_text.read_event stream)
  in
  ignore (B.await started : unit);
  B.cancel_fiber reading;
  (match B.await_cancelable reading with
  | `Cancelled | `Returned (Eta.Exit.Error _) -> ()
  | `Returned (Eta.Exit.Ok _) ->
      Alcotest.fail "transcription stream cancellation did not propagate");
  Alcotest.(check int) "transcription cancellation release" 1 !releases;
  let request_started, request_started_resolver = B.create_promise () in
  let request_gate, _request_gate_resolver = B.create_promise () in
  let blocking_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        E.sync (fun () -> B.try_resolve request_started_resolver ())
        |> E.bind (fun () -> B.await_effect request_gate)
        |> E.map (fun () -> response_of_bytes "{}"))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let translating =
    B.fork_run_cancelable ctx rt
      (O.Audio.Translation.create blocking_client
         ~api_key:(A.api_key "key") translation)
  in
  ignore (B.await request_started : unit);
  B.cancel_fiber translating;
  (match B.await_cancelable translating with
  | `Cancelled | `Returned (Eta.Exit.Error _) -> ()
  | `Returned (Eta.Exit.Ok _) ->
      Alcotest.fail "translation cancellation did not propagate");
  B.drain rt

let test_transcription_translation_safe_telemetry () =
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let provider = O.provider ~base_url:"https://api.openai.test:8443" () in
  let key = A.api_key "audio-api-key-sentinel" in
  let file =
    {
      A.Audio.filename = "sensitive-filename-sentinel.wav";
      content_type = "audio/wav";
      source = A.Audio.bytes (Bytes.of_string "source-audio-sentinel");
    }
  in
  let transcription =
    O.Audio.Speech_to_text.request
      ~model:O.Audio.Speech_to_text.Gpt_4o_transcribe ~file
      ~prompt:"transcription-prompt-sentinel" ()
    |> expect_ok "telemetry transcription"
  in
  let translation =
    O.Audio.Translation.request ~file
      ~prompt:"translation-prompt-sentinel" ()
    |> expect_ok "telemetry translation"
  in
  let transcription_client =
    test_client ~with_http_span:true
      (response_of_bytes {|{"text":"transcript-output-sentinel"}|})
      (ref None)
  in
  let translation_client =
    test_client ~with_http_span:true
      (response_of_bytes {|{"text":"translation-output-sentinel"}|})
      (ref None)
  in
  ignore
    (run_ok rt "traced transcription"
       (O.Audio.Speech_to_text.create ~provider transcription_client ~api_key:key
          transcription));
  ignore
    (run_ok rt "traced translation"
       (O.Audio.Translation.create ~provider translation_client ~api_key:key
          translation));
  let failure_client =
    test_client ~with_http_span:true
      (response_of_bytes ~status:400
         {|{"error":{"message":"audio-provider-message-sentinel","code":"audio_bad"}}|})
      (ref None)
  in
  ignore
    (B.run rt
       (O.Audio.Speech_to_text.create ~provider failure_client ~api_key:key
          transcription));
  let spans = Eta_observability.Tracer.dump tracer in
  let find_span name status =
    List.find
      (fun (span : Eta_observability.Tracer.span) ->
        String.equal span.name name && span.status = status)
      spans
  in
  let transcription_span =
    find_span "transcription.create openai" Eta_observability.Tracer.Ok
  in
  check_attr "transcription operation" "transcription.create"
    transcription_span.attrs "eta_ai.operation.name";
  check_attr "transcription format" "json" transcription_span.attrs
    "eta_ai.request.response_format";
  let translation_span =
    find_span "translation.create openai" Eta_observability.Tracer.Ok
  in
  check_attr "translation operation" "translation.create"
    translation_span.attrs "eta_ai.operation.name";
  check_attr "translation model" "whisper-1" translation_span.attrs
    "gen_ai.request.model";
  ignore
    (find_span "transcription.create openai"
       (Eta_observability.Tracer.Error "audio_bad"));
  let rendered =
    spans
    |> List.map (fun (span : Eta_observability.Tracer.span) ->
           span.name ^ "\n"
           ^ String.concat "\n"
               (List.map
                  (fun (name, value) -> name ^ "=" ^ value)
                  span.attrs))
    |> String.concat "\n"
  in
  List.iter
    (fun sentinel ->
      Alcotest.(check bool) ("telemetry excludes " ^ sentinel) false
        (contains ~needle:sentinel rendered))
    [
      "audio-api-key-sentinel";
      "sensitive-filename-sentinel";
      "source-audio-sentinel";
      "transcription-prompt-sentinel";
      "translation-prompt-sentinel";
      "transcript-output-sentinel";
      "translation-output-sentinel";
      "audio-provider-message-sentinel";
    ];
  Alcotest.(check bool) "wrapper nested HTTP spans suppressed" false
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "HTTP POST")
       spans)

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
      {
        model = O.Audio.Text_to_speech.Gpt_4o_mini_tts;
        instructions = Some "brief";
        extra = [];
      }
      construction
    |> expect_ok "oabridge-pmod/d348 OpenAI TTS configure"
  in
  Alcotest.(check string) "provider model supplied separately"
    "gpt-4o-mini-tts"
    (O.Audio.Text_to_speech.model_to_string configured.model);
  Alcotest.(check string) "neutral text converted" "hello" configured.input;
  Alcotest.(check bool) "neutral encoding converted" true
    (configured.response_format = Some O.Audio.Text_to_speech.Wav);
  (match
     O.Audio.Text_to_speech.configure
       {
         model = O.Audio.Text_to_speech.Other "";
         instructions = None;
         extra = [];
       }
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
        model = O.Audio.Speech_to_text.Whisper_1;
        prompt = Some "Eta";
        response_format = Some O.Audio.Speech_to_text.Verbose_json;
        temperature = Some 0.0;
        stream = None;
        include_ = [];
        timestamp_granularities = [];
        chunking_strategy = None;
        known_speaker_names = [];
        known_speaker_references = [];
        keywords = [];
        languages = [];
        extra_fields = [];
      }
      construction
    |> expect_ok "oabridge-pmod/d348 OpenAI STT configure"
  in
  Alcotest.(check string) "STT provider model supplied separately" "whisper-1"
    (O.Audio.Speech_to_text.model_to_string configured.model);
  (* oabridge-ff14: every neutral field is decoded from the provider body and
     projected; none is silently dropped. *)
  let body =
    {|{"text":"hello","language":"french","duration":12.5}|}
  in
  let decoded =
    O.Audio.Speech_to_text.decode_response
      (Some O.Audio.Speech_to_text.Verbose_json) body
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
    O.Audio.Speech_to_text.decode_response
      (Some O.Audio.Speech_to_text.Json) {|{"text":"hello"}|}
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
  (match O.encode_responses request with
  | Stdlib.Error (O.Error.Unsupported _) -> ()
  | _ -> Alcotest.fail "Responses audio must be rejected");
  List.iter
    (fun provider ->
      let tool_callbacks = ref 0 in
      match
        Eta_ai_openai_codec.encode_responses ~provider
          ~encode_tool:(fun _ ->
            incr tool_callbacks;
            Stdlib.Ok (A.Json.object_ []))
          request
      with
      | Stdlib.Error (A.Unsupported _) ->
          Alcotest.(check int) "codec tool callback" 0 !tool_callbacks
      | _ ->
          Alcotest.fail
            "the standard Responses codec must reject audio for every provider label")
    [ "openai"; "openrouter"; "custom" ];
  let common =
    {
      (chat_request ()) with
      model = "gpt-audio-1.5";
      prompt = [ A.User [ A.audio_pcm16_base64 "AAE=" ] ];
    }
  in
  (match O.Chat.request ~common () with
  | Stdlib.Error (O.Error.Unsupported _) -> ()
  | _ -> Alcotest.fail "Chat must reject undocumented pcm16 input");
  let wav =
    A.Audio { data = A.Base64 "AAE="; format = A.Wav; transcript = None }
  in
  let raw =
    O.Chat.request ~common:{ common with prompt = [ A.User [ wav ] ] } ()
    |> expect_ok "audio Chat request" |> O.Chat.encode
    |> expect_ok "audio Chat encode"
  in
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
  let raw =
    O.encode_chat (openai_chat_request request) |> expect_ok "image chat"
  in
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
  match Result.bind (O.Chat.request ~common:request ()) O.encode_chat with
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
     O.Audio.Speech_to_text.request
       ~model:(O.Audio.Speech_to_text.Other "m")
       ~file:
         {
           A.Audio.filename = "a.wav";
           content_type = "audio/wav\r\nX:1";
           source = A.Audio.bytes (Bytes.of_string "RIFF");
         }
       ()
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
      O.Error.Concurrent_use "speech audio";
      O.Error.Limit_exceeded
        { kind = "speech audio bytes"; limit = 1; actual = 2 };
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
      "concurrent_use";
      "limit_exceeded";
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
  let spans = Eta_observability.Tracer.dump tracer in
  let chat =
    List.find
      (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "chat gpt-4o-mini")
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
      (fun (span : Eta_observability.Tracer.span) ->
        List.assoc_opt "gen_ai.request.stream" span.attrs = Some "true")
      spans
  in
  check_attr "stream flag" "true" stream_span.attrs "gen_ai.request.stream";
  let embedding_span =
    List.find
      (fun (span : Eta_observability.Tracer.span) ->
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
      (fun (span : Eta_observability.Tracer.span) ->
        List.assoc_opt "error.type" span.attrs = Some "rate_limit_exceeded")
      spans
  in
  check_attr "error type" "rate_limit_exceeded" error_span.attrs "error.type";
  Alcotest.(check bool) "nested http span suppressed" false
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "HTTP POST")
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
  ignore
    (O.Chat.encode ~provider (openai_chat_request (chat_request ()))
    |> expect_ok "callback encode");
  Alcotest.(check bool) "encode callback" true !encode_hit;
  ignore
    (O.Chat.decode (read_fixture "chat_completion.json")
    |> expect_ok "callback decode");
  Alcotest.(check bool)
    "provider-owned buffered decoder bypasses neutral callback" false !decode_hit;
  with_runtime @@ fun rt ->
  let headers =
    H.Core.Header.unsafe_of_list [ ("content-type", "text/event-stream") ]
  in
  let client =
    test_client (response_of_fixture ~headers "stream_tool.sse") (ref None)
  in
  ignore
    (run_ok rt "callback stream"
       (O.Chat.stream ~provider client ~api_key:(A.api_key "sk")
          (openai_chat_request (chat_request ()))
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
          (openai_chat_request (chat_request ()))
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
         (openai_chat_request (chat_request ()))
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
    O.Chat.http_request ~provider:chat_provider ~api_key:(A.api_key "k")
      (openai_chat_request (chat_request ()))
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
         (openai_chat_request (chat_request ())))
  in
  Alcotest.(check string) "provider-owned Chat decoder"
    "gpt-4o-mini-2024-07-18" chat_response.model;
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
  Alcotest.(check bool)
    "Chat does not use the lossy neutral decode callback" false !chat_decode_hit;
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
  (match
     Result.bind
       (O.Chat.request
          ~common:{ (chat_request ()) with temperature = Some nan }
          ())
       O.encode_chat
   with
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
  O.chat_completions_request ~api_key:(A.api_key "k")
    (openai_chat_request bad_chat)
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
    (O.chat_completions client ~api_key:(A.api_key "k")
       (openai_chat_request bad_chat));
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
      ~api_key:(A.api_key "sk") (openai_chat_request (chat_request ()))
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
        ~api_key:(A.api_key "sk") (openai_chat_request (chat_request ()))
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
            (openai_chat_request (chat_request ()))
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
          (openai_chat_request (chat_request ()))
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
          (openai_chat_request (chat_request ()))
       |> E.bind O.read_stream_event)
   with
  | Eta.Exit.Error cause ->
      if not (has_read_primary cause) then
        Alcotest.failf "body read primary missing from %a"
          (Eta.Cause.pp O.Error.pp) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "body read plus release unexpectedly succeeded");
  Alcotest.(check int) "body read failure releases exactly once" 1 !read_releases

let test_oachat_runner_preflight_replay_concurrency_and_telemetry () =
  let audio =
    A.Audio
      {
        data = A.Base64 "AA==";
        format = A.Wav;
        transcript = None;
      }
  in
  let responses_audio role : A.tool A.Responses.request =
    let message =
      match role with
      | 0 -> A.User [ audio ]
      | 1 -> A.Assistant { content = [ audio ]; tool_calls = [] }
      | 2 -> A.Tool { tool_call_id = "call"; content = [ audio ] }
      | _ -> A.User [ A.Text "before"; audio; A.Text "after" ]
    in
    { (responses_request ()) with input = A.Responses.Messages [ message ] }
  in
  B.with_traced_runtime @@ fun ctx rt tracer ->
  let provider_callbacks = ref 0 in
  let body_allocations = ref 0 in
  let responses_base = O.responses_provider () in
  let responses_provider =
    {
      responses_base with
      A.encode_responses =
        (fun request ->
          incr provider_callbacks;
          incr body_allocations;
          responses_base.encode_responses request);
    }
  in
  let http_callbacks = ref 0 in
  let unreachable_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        incr http_callbacks;
        E.pure (response_of_fixture "responses.json"))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  List.iter
    (fun role ->
      let request = responses_audio role in
      let expect_preflight label = function
        | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Unsupported _)) -> ()
        | _ -> Alcotest.fail (label ^ " did not fail before transport")
      in
      B.run rt
        (O.responses ~provider:responses_provider unreachable_client
           ~api_key:(A.api_key "runner-key") request)
      |> expect_preflight "Responses run";
      B.run rt
        (O.stream_responses ~provider:responses_provider unreachable_client
           ~api_key:(A.api_key "runner-key") request)
      |> expect_preflight "Responses stream")
    [ 0; 1; 2; 3 ];
  Alcotest.(check int) "Responses provider callbacks" 0 !provider_callbacks;
  Alcotest.(check int) "Responses body allocations" 0 !body_allocations;
  Alcotest.(check int) "Responses HTTP callbacks" 0 !http_callbacks;
  let chat_base = O.chat_completions_provider () in
  let chat_encodes = ref 0 in
  let chat_provider =
    {
      chat_base with
      A.encode_chat =
        (fun request ->
          incr chat_encodes;
          chat_base.encode_chat request);
    }
  in
  (match
     O.Chat.request
       ~common:
         {
           (chat_request ()) with
           prompt =
             [
               A.User
                 [
                   A.Audio
                     {
                       data = A.Base64 "AB==";
                       format = A.Wav;
                       transcript = None;
                     };
                 ];
             ];
         }
       ()
   with
  | Error (O.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "noncanonical caller Base64 was accepted");
  Alcotest.(check int) "invalid Base64 has no encode callback" 0 !chat_encodes;
  Alcotest.(check int) "invalid Base64 has no HTTP callback" 0 !http_callbacks;
  let output =
    O.Chat.request ~common:(chat_request ())
      ~modalities:[ O.Chat.Text; O.Chat.Audio ]
      ~audio:
        {
          O.Chat.voice = O.Voices.Built_in O.Voices.Alloy;
          format = O.Chat.Wav;
        }
      ()
    |> expect_ok "audio output request"
  in
  (match
     B.run rt
       (O.Chat.stream ~provider:chat_provider unreachable_client
          ~api_key:(A.api_key "runner-key") output)
   with
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Unsupported _)) -> ()
  | _ -> Alcotest.fail "streamed audio output reached transport");
  Alcotest.(check int) "output stream encode callback" 0 !chat_encodes;
  Alcotest.(check int) "output stream HTTP callback" 0 !http_callbacks;
  let input =
    O.Chat.request
      ~common:{ (chat_request ()) with prompt = [ A.User [ audio ] ] }
      ()
    |> expect_ok "audio input request"
  in
  let input_releases = ref 0 in
  let input_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        incr http_callbacks;
        let body =
          H.Body.Stream.of_bytes
            ~release:(fun () -> E.sync (fun () -> incr input_releases))
            [ Bytes.of_string "data: [DONE]\n\n" ]
        in
        E.pure
          (H.Response.make ~status:200
             ~headers:
               (H.Core.Header.unsafe_of_list
                  [ ("content-type", "text/event-stream") ])
             ~body ()))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let input_stream =
    run_ok rt "streamed input audio"
      (O.Chat.stream ~provider:chat_provider input_client
         ~api_key:(A.api_key "runner-key") input)
  in
  run_ok rt "close streamed input audio" (O.close_stream input_stream);
  Alcotest.(check int) "input stream encode callback" 1 !chat_encodes;
  Alcotest.(check int) "input stream HTTP callback" 1 !http_callbacks;
  Alcotest.(check int) "input stream release" 1 !input_releases;
  let structured =
    O.structured_output ~name:"shape" ~schema_json:"{\"type\":\"object\"}" ()
    |> expect_ok "structured output"
  in
  (match O.Chat.encode ~structured_output:structured ~provider:chat_provider input with
  | Error (O.Error.Unsupported _) -> ()
  | _ -> Alcotest.fail "input audio plus structured output accepted");
  (match
     O.Chat.http_request ~structured_output:structured ~provider:chat_provider
       ~api_key:(A.api_key "runner-key") output
   with
  | Error (O.Error.Unsupported _) -> ()
  | _ -> Alcotest.fail "output audio plus structured output accepted");
  Alcotest.(check int) "structured rejection has no encode callback" 1
    !chat_encodes;
  let response_counter = Atomic.make 0 in
  let releases = Atomic.make 0 in
  let response_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        E.sync (fun () ->
            let ordinal = Atomic.fetch_and_add response_counter 1 + 1 in
            let raw =
              read_fixture "chat_completion.json" |> A.Json.parse
              |> Result.get_ok
              |> (function
                   | `Assoc fields -> (
                       match List.assoc_opt "choices" fields with
                       | Some (`List [ (`Assoc choice_fields as first) ]) ->
                           let second =
                             `Assoc
                               (("index", `Int 1)
                               :: ("finish_reason", `String "length")
                               :: List.remove_assoc "index"
                                    (List.remove_assoc "finish_reason"
                                       choice_fields))
                           in
                           `Assoc
                             (("id", `String (Printf.sprintf "chat-%d" ordinal))
                             :: ("choices", `List [ first; second ])
                             :: List.remove_assoc "id"
                                  (List.remove_assoc "choices" fields))
                       | None | Some _ -> assert false)
                   | _ -> assert false)
              |> A.Json.to_string
            in
            let body =
              H.Body.Stream.of_bytes
                ~release:(fun () ->
                  E.sync (fun () -> Atomic.incr releases))
                [ Bytes.of_string raw ]
            in
            H.Response.make ~status:200 ~body ()))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let telemetry_audio_bytes = "audio-content-sentinel" in
  let telemetry_audio_base64 = Base64.encode_string telemetry_audio_bytes in
  let telemetry_common =
    {
      (chat_request ()) with
      prompt =
        (chat_request ()).prompt
        @
        [
          A.User
            [
              A.Audio
                {
                  data = A.Base64 telemetry_audio_base64;
                  format = A.Wav;
                  transcript = Some "audio-transcript-sentinel";
                };
            ];
        ];
    }
  in
  let program =
    O.Chat.run response_client ~api_key:(A.api_key "runner-secret-key")
      (openai_chat_request telemetry_common)
  in
  let first = run_ok rt "Chat replay first" program in
  let second = run_ok rt "Chat replay second" program in
  Alcotest.(check string) "first replay response" "chat-1" first.id;
  Alcotest.(check string) "second replay response" "chat-2" second.id;
  let concurrent =
    run_ok rt "Chat concurrent replay" (E.all [ program; program ])
  in
  Alcotest.(check (list string)) "concurrent responses are independent"
    [ "chat-3"; "chat-4" ]
    (concurrent |> List.map (fun response -> response.O.Chat.id)
    |> List.sort String.compare);
  Alcotest.(check int) "all buffered bodies released" 4 (Atomic.get releases);
  let started, started_resolver = B.create_promise () in
  let gate, _gate_resolver = B.create_promise () in
  let cancelled_releases = Atomic.make 0 in
  let blocked_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ ->
        let body =
          H.Body.Stream.of_reader
            ~release:(fun () ->
              E.sync (fun () -> Atomic.incr cancelled_releases))
            (fun () ->
              E.sync (fun () -> B.try_resolve started_resolver ())
              |> E.bind (fun () -> B.await_effect gate)
              |> E.map (fun () -> H.Body.Stream.End))
        in
        E.pure (H.Response.make ~status:200 ~body ()))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  let blocked =
    B.fork_run_cancelable ctx rt
      (O.Chat.run blocked_client ~api_key:(A.api_key "runner-key")
         (openai_chat_request (chat_request ())))
  in
  ignore (B.await started : unit);
  B.cancel_fiber blocked;
  ignore (B.await_cancelable blocked);
  Alcotest.(check int) "cancelled Chat body release" 1
    (Atomic.get cancelled_releases);
  let spans = Eta_observability.Tracer.dump tracer in
  let chat_spans =
    List.filter
      (fun (span : Eta_observability.Tracer.span) -> String.equal span.name "chat openai")
      spans
  in
  Alcotest.(check int) "successful Chat telemetry spans" 4
    (List.length
       (List.filter
          (fun (span : Eta_observability.Tracer.span) -> span.status = Eta_observability.Tracer.Ok)
          chat_spans));
  let successful_spans =
    List.filter
      (fun (span : Eta_observability.Tracer.span) -> span.status = Eta_observability.Tracer.Ok)
      chat_spans
  in
  let returned = first :: second :: concurrent in
  Alcotest.(check (list string))
    "exact replay and concurrency response ids"
    [ "chat-1"; "chat-2"; "chat-3"; "chat-4" ]
    (returned
    |> List.map (fun response -> response.O.Chat.id)
    |> List.sort String.compare);
  let attrs_for_response (response : O.Chat.response) =
    let usage =
      match response.usage with
      | Some usage -> usage
      | None -> Alcotest.fail "issued Chat response missing usage"
    in
    Alcotest.(check string) "issued response model"
      "gpt-4o-mini-2024-07-18" response.model;
    Alcotest.(check int) "issued prompt usage" 11 usage.prompt_tokens;
    Alcotest.(check int) "issued completion usage" 5 usage.completion_tokens;
    Alcotest.(check (list string)) "issued finish reasons"
      [ "stop"; "length" ]
      (List.map (fun choice -> choice.O.Chat.finish_reason) response.choices);
    [
      ("gen_ai.operation.name", "chat");
      ("gen_ai.provider.name", "openai");
      ("gen_ai.request.model", "gpt-4o-mini");
      ("server.address", "api.openai.com");
      ("server.port", "443");
      ("gen_ai.response.id", response.id);
      ("gen_ai.response.model", response.model);
      ("gen_ai.response.finish_reasons", "stop,length");
      ("gen_ai.usage.input_tokens", string_of_int usage.prompt_tokens);
      ("gen_ai.usage.output_tokens", string_of_int usage.completion_tokens);
    ]
    |> List.sort compare
  in
  let sort_by_id attrs =
    match List.assoc_opt "gen_ai.response.id" attrs with
    | Some id -> id
    | None -> Alcotest.fail "Chat span missing response id"
  in
  let expected =
    returned |> List.map attrs_for_response
    |> List.sort (fun left right ->
           String.compare (sort_by_id left) (sort_by_id right))
  in
  let actual =
    successful_spans
    |> List.map (fun (span : Eta_observability.Tracer.span) -> List.sort compare span.attrs)
    |> List.sort (fun left right ->
           String.compare (sort_by_id left) (sort_by_id right))
  in
  Alcotest.(check (list (list (pair string string))))
    "exact correlated Chat GenAI success attributes"
    expected actual;
  let rendered =
    chat_spans
    |> List.concat_map (fun (span : Eta_observability.Tracer.span) ->
           span.attrs |> List.map (fun (name, value) -> name ^ "=" ^ value))
    |> String.concat "\n"
  in
  List.iter
    (fun secret ->
      Alcotest.(check bool) ("Chat telemetry excludes " ^ secret) false
        (contains ~needle:secret rendered))
    [
      "runner-secret-key";
      "weather in Warsaw";
      "stay brief";
      telemetry_audio_bytes;
      telemetry_audio_base64;
      "audio-transcript-sentinel";
      "Sunny and 68F";
    ]

let test_aierr_openai_of_ai_error_invalid_request_roundtrip () =
  match
    O.Error.of_ai_error
      (A.Invalid_request { provider = "openai"; message = "x" })
  with
  | O.Error.Invalid_request "x" -> ()
  | O.Error.Provider_response _ ->
      Alcotest.fail "must not reclassify Invalid_request as Provider_response"
  | _ -> Alcotest.fail "expected Invalid_request roundtrip"

let test_oachat_gen_ai_error_attrs_all_nominal_classes () =
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let secret = "prompt-audio-base64-api-key-secret" in
  let base_provider =
    {
      (O.chat_completions_provider
         ~base_url:"https://custom.example:8443" ())
      with
      A.name = "custom-provider";
    }
  in
  let request = openai_chat_request (chat_request ()) in
  let unreachable = test_client (response_of_bytes "unreachable") (ref None) in
  let local ai_error =
    let provider =
      { base_provider with A.encode_chat = (fun _ -> Error ai_error) }
    in
    O.Chat.run ~provider unreachable ~api_key:(A.api_key secret) request
  in
  let http_error =
    H.Error.make ~method_:"POST"
      ~uri:"https://custom.example:8443/v1/chat"
      (H.Error.Connect_error { message = secret })
  in
  let failing_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ -> E.fail http_error)
      ~stats:(fun () -> E.pure None)
      ~shutdown:(fun () -> E.unit)
  in
  let response_effect response =
    O.Chat.run ~provider:base_provider
      (test_client response (ref None))
      ~api_key:(A.api_key secret) request
  in
  let effects =
    [
      ( local (A.Invalid_request { provider = "custom"; message = secret }),
        "invalid_request" );
      ( local (A.Unsupported { provider = "custom"; feature = secret }),
        "unsupported" );
      (local (A.Invalid_tool { name = secret; message = secret }), "invalid_tool");
      ( local
          (A.Provider_error
             {
               provider = "custom";
               status = None;
               code = None;
               message = secret;
               raw = Some secret;
               retry_after_s = None;
             }),
        "provider_error" );
      ( local
          (A.Provider_error
             {
               provider = "custom";
               status = None;
               code = Some "concurrent_use";
               message = secret;
               raw = Some secret;
               retry_after_s = None;
             }),
        "concurrent_use" );
      ( local
          (A.Provider_error
             {
               provider = "custom";
               status = None;
               code = Some "limit_exceeded";
               message = secret;
               raw = Some secret;
               retry_after_s = None;
             }),
        "limit_exceeded" );
      ( O.Chat.run ~provider:base_provider failing_client
          ~api_key:(A.api_key secret) request,
        "http_error" );
      ( response_effect
          (response_of_bytes ~status:429
             {|{"error":{"code":"remote_code","type":"remote_type","message":"prompt-audio-base64-api-key-secret"}}|}),
        "remote_code" );
      ( response_effect
          (response_of_bytes ~status:400
             {|{"error":{"message":"prompt-audio-base64-api-key-secret"}}|}),
        "provider_error" );
      (response_effect (response_of_bytes ~status:500 secret), "unknown_response");
      (response_effect (response_of_bytes "{}"), "decode_error");
    ]
  in
  List.iter
    (fun (program, _) ->
      match B.run rt program with
      | Eta.Exit.Error (Eta.Cause.Fail _) -> ()
      | Eta.Exit.Ok _ | Eta.Exit.Error _ ->
          Alcotest.fail "nominal telemetry error did not remain primary")
    effects;
  let spans =
    Eta_observability.Tracer.dump tracer
    |> List.filter (fun (span : Eta_observability.Tracer.span) ->
           String.equal span.name "chat custom-provider")
  in
  Alcotest.(check int) "one span per reachable nominal failure class"
    (List.length effects) (List.length spans);
  let actual_error_types =
    spans
    |> List.filter_map (fun (span : Eta_observability.Tracer.span) ->
           let error_type = List.assoc_opt "error.type" span.attrs in
           let expected_base =
             [
               ("gen_ai.operation.name", "chat");
               ("gen_ai.provider.name", "custom-provider");
               ("gen_ai.request.model", "gpt-4o-mini");
               ("server.address", "custom.example");
               ("server.port", "8443");
             ]
           in
           (match error_type with
           | None -> Alcotest.fail "failed GenAI span omitted error.type"
           | Some error_type ->
               Alcotest.(check (list (pair string string)))
                 "exact Chat GenAI failure attributes"
                 (List.sort compare (("error.type", error_type) :: expected_base))
                 (List.sort compare span.attrs));
           error_type)
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "reachable nominal error classifications"
    (effects |> List.map snd |> List.sort String.compare)
    actual_error_types;
  let rendered =
    spans
    |> List.concat_map (fun (span : Eta_observability.Tracer.span) ->
           List.map (fun (name, value) -> name ^ "=" ^ value) span.attrs)
    |> String.concat "\n"
  in
  Alcotest.(check bool)
    "error telemetry excludes prompt audio base64 API key and content" false
    (contains ~needle:secret rendered)

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
          Alcotest.test_case
            "oachat runner preflight replay concurrency telemetry cleanup"
            `Quick
            test_oachat_runner_preflight_replay_concurrency_and_telemetry;
          Alcotest.test_case "oachat exact GenAI nominal error attributes" `Quick
            test_oachat_gen_ai_error_attrs_all_nominal_classes;
          Alcotest.test_case "aierr of_ai_error invalid_request roundtrip" `Quick
            test_aierr_openai_of_ai_error_invalid_request_roundtrip;
          Alcotest.test_case "responses request" `Quick
            test_responses_request_uses_responses_endpoint;
          Alcotest.test_case "embeddings request and decode" `Quick
            test_embeddings_request_and_decode;
          Alcotest.test_case "image generation request and decode" `Quick
            test_image_generation_request_and_decode;
          Alcotest.test_case "speech runner" `Quick test_speech_runner;
          Alcotest.test_case "oatts full request vocabulary" `Quick
            test_oatts_speech_full_request_vocabulary;
          Alcotest.test_case "oaerr speech validation matrix" `Quick
            test_oaerr_speech_validation_matrix;
          Alcotest.test_case "oatts raw stream collection and release" `Quick
            test_oatts_raw_stream_chunks_collection_and_release;
          Alcotest.test_case "oatts SSE unknown bounds and release" `Quick
            test_oatts_sse_unknown_bounds_and_release;
          Alcotest.test_case "oastr concurrent use and cancellation" `Quick
            test_oastr_speech_concurrent_use_and_cancellation;
          Alcotest.test_case "oastr effect construction is inert" `Quick
            test_oastr_speech_effect_construction_is_inert;
          Alcotest.test_case "oastr close cancellation waits for release" `Quick
            test_oastr_speech_close_cancellation_waits_for_release;
          Alcotest.test_case "oastr primary cleanup precedence" `Quick
            test_oastr_speech_primary_cleanup_precedence;
          Alcotest.test_case "oaerr speech runner failure matrix" `Quick
            test_oaerr_speech_runner_failure_matrix;
          Alcotest.test_case "oaobs speech safe attributes" `Quick
            test_oaobs_speech_safe_attributes;
          Alcotest.test_case "transcription request and decode" `Quick
            test_transcription_request_and_decode;
          Alcotest.test_case
            "transcription canonical format validation and decode" `Quick
            test_transcription_format_canonicalization_and_validation;
          Alcotest.test_case "transcription buffered result matrix" `Quick
            test_transcription_buffered_result_matrix;
          Alcotest.test_case "translation result and malformed matrix" `Quick
            test_translation_result_and_malformed_matrix;
          Alcotest.test_case "transcription multipart validation" `Quick
            test_transcription_request_rejects_multipart_header_injection;
          Alcotest.test_case "transcription multipart boundary collision" `Quick
            test_transcription_request_avoids_boundary_collision;
          Alcotest.test_case "transcription streaming multipart and translation"
            `Quick test_transcription_streaming_multipart_and_translation;
          Alcotest.test_case
            "transcription chunking speakers repetition and size" `Quick
            test_transcription_chunking_speakers_repetition_and_size;
          Alcotest.test_case "transcription typed SSE events and release" `Quick
            test_transcription_stream_events_typed_and_released;
          Alcotest.test_case
            "transcription translation wrapper failure lifecycle" `Quick
            test_transcription_translation_wrapper_failures_and_large_errors;
          Alcotest.test_case "transcription translation safe telemetry" `Quick
            test_transcription_translation_safe_telemetry;
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
