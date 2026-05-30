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

let embedding_request () : A.Embedding.request =
  {
    model = "openai/text-embedding-3-small";
    input = A.Embedding.Text "The quick brown fox";
    encoding_format = Some "float";
    dimensions = Some 1536;
    user = Some "eta-test-user";
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
  Alcotest.(check bool) "embeddings" true provider.capabilities.embeddings;
  Alcotest.(check bool) "image input" true provider.capabilities.image_input;
  Alcotest.(check bool) "audio prompt input" false provider.capabilities.audio_input;
  Alcotest.(check bool) "video prompt input" false provider.capabilities.video_input;
  Alcotest.(check bool) "image generation" true provider.capabilities.image_generation;
  Alcotest.(check bool) "speech" true provider.capabilities.speech;
  Alcotest.(check bool) "transcription" true provider.capabilities.transcription;
  Alcotest.(check bool) "rerank" true provider.capabilities.rerank;
  Alcotest.(check bool) "video generation" true provider.capabilities.video_generation;
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
    O.encode_responses ~structured_output:output ~routing:(routing ())
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

let test_unified_provider_modules () =
  let provider = provider () in
  let chat =
    O.Chat.request ~provider ~api_key:(A.api_key "or-test") (chat_request ())
    |> expect_ok "unified chat request"
  in
  Alcotest.(check string)
    "chat uri" "https://openrouter.ai/api/v1/responses" chat.uri;
  let embeddings =
    O.Embeddings.request ~provider ~api_key:(A.api_key "or-test")
      (embedding_request ())
    |> expect_ok "unified embeddings request"
  in
  Alcotest.(check string)
    "embeddings uri" "https://openrouter.ai/api/v1/embeddings"
    embeddings.uri;
  let raw =
    O.Embeddings.encode ~provider (embedding_request ())
    |> expect_ok "unified embeddings encode"
  in
  require_contains "unified embeddings model"
    ~needle:"\"model\":\"openai/text-embedding-3-small\"" raw

let test_encode_embeddings_and_request_endpoint () =
  let raw =
    O.encode_embeddings ~routing:(routing ()) ~input_type:"search_document"
      (embedding_request ())
    |> expect_ok "embeddings encode"
  in
  require_contains "model" ~needle:"\"model\":\"openai/text-embedding-3-small\""
    raw;
  require_contains "input" ~needle:"\"input\":\"The quick brown fox\"" raw;
  require_contains "format" ~needle:"\"encoding_format\":\"float\"" raw;
  require_contains "dimensions" ~needle:"\"dimensions\":1536" raw;
  require_contains "user" ~needle:"\"user\":\"eta-test-user\"" raw;
  require_contains "input type" ~needle:"\"input_type\":\"search_document\"" raw;
  require_contains "routing" ~needle:"\"provider\":{" raw;
  let request =
    O.embeddings_request ~routing:(routing ()) ~input_type:"search_document"
      ~provider:(provider ()) ~api_key:(A.api_key "or-test")
      (embedding_request ())
    |> expect_ok "embeddings request"
  in
  Alcotest.(check string)
    "uri" "https://openrouter.ai/api/v1/embeddings" request.uri;
  require_contains "request body" ~needle:"\"dimensions\":1536"
    (request_body_string request);
  (match
     O.encode_embeddings
       { (embedding_request ()) with dimensions = Some 0 }
   with
  | Stdlib.Error (A.Unsupported { provider = "openrouter"; _ }) -> ()
  | _ -> Alcotest.fail "expected invalid dimensions rejection");
  match
    O.encode_embeddings
      { (embedding_request ()) with encoding_format = Some "binary" }
  with
  | Stdlib.Error (A.Unsupported { provider = "openrouter"; _ }) -> ()
  | _ -> Alcotest.fail "expected invalid encoding_format rejection"

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

let test_decode_embeddings_fixture () =
  let response =
    O.decode_embeddings (read_fixture "embeddings.json")
    |> expect_ok "embeddings"
  in
  Alcotest.(check (option string))
    "id" (Some "emb-openrouter-fixture") response.id;
  Alcotest.(check (option string))
    "model" (Some "openai/text-embedding-3-small")
    response.model;
  Alcotest.(check int) "embedding count" 2 (List.length response.embeddings);
  (match response.embeddings with
  | { A.Embedding.embedding = A.Embedding.Float values; index = Some 0 } :: _ ->
      Alcotest.(check int) "float dimensions" 3 (List.length values)
  | _ -> Alcotest.fail "expected float embedding");
  (match List.nth response.embeddings 1 with
  | { A.Embedding.embedding = A.Embedding.Base64 value; index = Some 1 } ->
      Alcotest.(check string) "base64" "AAECAwQ=" value
  | _ -> Alcotest.fail "expected base64 embedding");
  Alcotest.(check (option int))
    "input tokens" (Some 7)
    (Option.bind response.usage (fun usage ->
         usage.input_tokens));
  Alcotest.(check (option int))
    "total tokens" (Some 7)
    (Option.bind response.usage (fun usage ->
         usage.total_tokens))

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

let span_attr key (span : Eta.Tracer.span) = List.assoc_opt key span.attrs

let require_span_attr span key expected =
  Alcotest.(check (option string)) key (Some expected) (span_attr key span)

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

let test_embeddings_runner () =
  with_traced_runtime @@ fun rt tracer ->
  let captured = ref None in
  let client =
    test_client ~with_http_span:true (response_of_fixture "embeddings.json")
      captured
  in
  let response =
    run_ok rt "embeddings runner"
      (O.embeddings ~routing:(routing ()) ~input_type:"search_query"
         ~provider:(provider ()) client ~api_key:(A.api_key "or-test")
         (embedding_request ()))
  in
  Alcotest.(check int) "embedding count" 2 (List.length response.embeddings);
  let request =
    match !captured with
    | Some request -> request
    | None -> Alcotest.fail "expected embeddings request"
  in
  Alcotest.(check string)
    "uri" "https://openrouter.ai/api/v1/embeddings" request.uri;
  require_contains "request input type" ~needle:"\"input_type\":\"search_query\""
    (request_body_string request);
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool)
    "transport span suppressed" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
       spans);
  let span =
    match
      List.find_opt
        (fun (span : Eta.Tracer.span) ->
          String.equal span.name "embeddings openai/text-embedding-3-small")
        spans
    with
    | Some span -> span
    | None -> Alcotest.fail "expected embeddings span"
  in
  require_span_attr span "gen_ai.operation.name" "embeddings";
  require_span_attr span "gen_ai.request.encoding_formats" "float";
  require_span_attr span "gen_ai.usage.input_tokens" "7";
  require_span_attr span "gen_ai.usage.total_tokens" "7"

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

let transcription_request () : A.Transcription.request =
  {
    model = "openai/whisper-large-v3";
    file =
      { filename = "sample.wav"; content_type = "audio/wav"; data = Bytes.of_string "RIFF" };
    language = Some "en";
    prompt = None;
    response_format = None;
    temperature = Some 0.0;
    extra_fields = [];
  }

let test_encode_and_decode_task_apis () =
  let speech =
    O.encode_speech
      {
        A.Speech.model = "elevenlabs/eleven-turbo-v2";
        input = "hello";
        voice = "alloy";
        response_format = Some "pcm";
        speed = Some 1.0;
        instructions = None;
        extra = [];
      }
    |> expect_ok "speech encode"
  in
  require_contains "speech model" ~needle:"\"model\":\"elevenlabs/eleven-turbo-v2\"" speech;
  let transcription =
    O.encode_transcription (transcription_request ())
    |> expect_ok "transcription encode"
  in
  require_contains "stt input" ~needle:"\"input_audio\":{" transcription;
  let transcription_response =
    O.decode_transcription (read_fixture "transcription.json")
    |> expect_ok "transcription fixture"
  in
  Alcotest.(check (option string))
    "transcription text" (Some "openrouter speech")
    transcription_response.text;
  let raw =
    O.encode_image_generation
      {
        A.Image.model = Some "google/gemini-3.1-flash-image-preview";
        prompt = "draw eta";
        n = None;
        size = Some "1K";
        quality = None;
        response_format = None;
        user = None;
        extra = [];
      }
    |> expect_ok "image generation encode"
  in
  require_contains "image modality" ~needle:"\"modalities\":[\"image\",\"text\"]" raw;
  let image_response =
    O.decode_image_generation (read_fixture "image_generation.json")
    |> expect_ok "image generation fixture"
  in
  Alcotest.(check int) "image count" 1 (List.length image_response.images);
  let rerank =
    O.decode_rerank (read_fixture "rerank.json") |> expect_ok "rerank fixture"
  in
  Alcotest.(check int) "rerank count" 1 (List.length rerank.results);
  let video =
    O.decode_video (read_fixture "video.json") |> expect_ok "video fixture"
  in
  Alcotest.(check string) "video id" "video_job" video.id

let test_task_request_endpoints_and_binary_runners () =
  let provider = provider () in
  let rerank_request =
    O.rerank_request ~provider ~api_key:(A.api_key "or-test")
      {
        A.Rerank.model = "cohere/rerank-v3.5";
        query = "effects";
        documents = [ "Eta"; "Other" ];
        top_n = Some 1;
      }
    |> expect_ok "rerank request"
  in
  Alcotest.(check string)
    "rerank uri" "https://openrouter.ai/api/v1/rerank" rerank_request.uri;
  let video_request =
    O.video_request ~provider ~api_key:(A.api_key "or-test")
      {
        A.Video.model = "google/veo-3.1";
        prompt = "mountains";
        aspect_ratio = Some "16:9";
        duration = Some 8;
        resolution = Some "720p";
        extra = [];
      }
    |> expect_ok "video request"
  in
  Alcotest.(check string)
    "video uri" "https://openrouter.ai/api/v1/videos" video_request.uri;
  let image_request =
    O.image_generation_request ~provider ~api_key:(A.api_key "or-test")
      {
        A.Image.model = Some "google/gemini-3.1-flash-image-preview";
        prompt = "draw eta";
        n = None;
        size = None;
        quality = None;
        response_format = None;
        user = None;
        extra = [];
      }
    |> expect_ok "image request"
  in
  Alcotest.(check string)
    "image uri" "https://openrouter.ai/api/v1/chat/completions"
    image_request.uri;
  let content_request =
    O.video_content_request ~provider ~api_key:(A.api_key "or-test")
      { A.Video.job_id = "video_job"; index = Some 1 }
    |> expect_ok "video content request"
  in
  Alcotest.(check string)
    "video content uri"
    "https://openrouter.ai/api/v1/videos/video_job/content?index=1"
    content_request.uri;
  with_runtime @@ fun rt ->
  let captured = ref None in
  let client =
    test_client
      (response_of_bytes ~headers:[ ("Content-Type", "audio/pcm") ] "PCM")
      captured
  in
  let speech =
    run_ok rt "speech"
      (O.speech ~provider client ~api_key:(A.api_key "or-test")
         {
           A.Speech.model = "elevenlabs/eleven-turbo-v2";
           input = "hello";
           voice = "alloy";
           response_format = Some "pcm";
           speed = None;
           instructions = None;
           extra = [];
         })
  in
  Alcotest.(check string) "speech bytes" "PCM" (Bytes.to_string speech.audio)

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
          Alcotest.test_case "unified provider modules" `Quick
            test_unified_provider_modules;
          Alcotest.test_case "embeddings request endpoint" `Quick
            test_encode_embeddings_and_request_endpoint;
        ] );
      ( "fixtures",
        [
          Alcotest.test_case "decode responses fixtures" `Quick
            test_decode_responses_fixtures;
          Alcotest.test_case "decode embeddings fixture" `Quick
            test_decode_embeddings_fixture;
          Alcotest.test_case "task API codecs" `Quick
            test_encode_and_decode_task_apis;
          Alcotest.test_case "midstream error" `Quick
            test_stream_midstream_error_fixture;
        ] );
      ( "http",
        [
          Alcotest.test_case "runner suppression" `Quick
            test_runner_suppresses_transport_span;
          Alcotest.test_case "provider error" `Quick test_provider_error;
          Alcotest.test_case "embeddings runner" `Quick test_embeddings_runner;
          Alcotest.test_case "task request endpoints and binary runners" `Quick
            test_task_request_endpoints_and_binary_runners;
          Alcotest.test_case "stream runner" `Quick test_stream_runner;
        ] );
    ]
