module A = Eta_ai
module O = Eta_ai_openai
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
    model = "gpt-4o-mini";
    prompt = [ A.System "stay brief"; A.User [ A.Text "weather in Warsaw" ] ];
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

let response_of_bytes ?(status = 200) ?(headers = []) body =
  H.Response.make ~status ~headers
    ~body:(H.Body.Stream.of_bytes [ Bytes.of_string body ])
    ()

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
    (Option.bind response.usage (fun usage -> usage.A.input_tokens))

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
    H.Core.Header.unsafe_of_list [ ("content-type", "application/json") ]
  in
  let client =
    test_client
      (response_of_fixture ~status:429 ~headers "error.json")
      captured
  in
  match
    Eta.Runtime.run rt
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

let test_chat_and_responses_encode_audio_content () =
  let request =
    { (chat_request ()) with prompt = [ A.User [ A.audio_pcm16_base64 "AAE=" ] ] }
  in
  let raw = O.encode_responses request |> expect_ok "audio responses" in
  require_contains "audio part" ~needle:"\"type\":\"input_audio\"" raw;
  require_contains "audio data" ~needle:"\"data\":\"AAE=\"" raw

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
    |> expect_ok "audio append event"
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

let () =
  Alcotest.run "eta-ai-openai"
    [
      ( "provider",
        [
          Alcotest.test_case "value" `Quick test_provider_value;
          Alcotest.test_case "encode chat and responses" `Quick
            test_encode_chat_and_responses;
          Alcotest.test_case "encodes audio content" `Quick
            test_chat_and_responses_encode_audio_content;
        ] );
      ( "decode",
        [
          Alcotest.test_case "chat fixture" `Quick test_decode_chat_fixture;
          Alcotest.test_case "tool fixture" `Quick test_decode_tool_fixture;
          Alcotest.test_case "responses fixture" `Quick
            test_decode_responses_fixture;
        ] );
      ( "streaming",
        [
          Alcotest.test_case "SSE fixture" `Quick test_stream_fixture;
          Alcotest.test_case "stream runner" `Quick test_stream_runner;
        ] );
      ( "http",
        [
          Alcotest.test_case "responses runner" `Quick
            test_responses_runner_uses_eta_http_and_suppresses_transport_span;
          Alcotest.test_case "provider error" `Quick
            test_responses_runner_provider_error;
          Alcotest.test_case "responses request" `Quick
            test_responses_request_uses_responses_endpoint;
          Alcotest.test_case "embeddings request and decode" `Quick
            test_embeddings_request_and_decode;
          Alcotest.test_case "image generation request and decode" `Quick
            test_image_generation_request_and_decode;
          Alcotest.test_case "speech runner" `Quick test_speech_runner;
          Alcotest.test_case "transcription request and decode" `Quick
            test_transcription_request_and_decode;
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
