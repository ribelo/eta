# eta_ai Core Tutorial

eta_ai core defines the common AI vocabulary and effect wrappers used by
provider packages. It does not own application state and it does not ship a
provider implementation by itself.

Provider packages such as eta_ai_openai and eta_ai_anthropic will construct
provider values. Applications pass dependencies and state in ordinary OCaml.

## What Core Provides

- messages, prompts, responses, usage, tools, and typed AI errors;
- text, image, audio, video, embedding, speech, transcription, rerank, and
  video-generation vocabulary;
- provider records with endpoint data and provider-local codecs;
- raw JSON tool schemas until eta_schema can export JSON Schema;
- SSE pull parsing over eta_http response bodies;
- GenAI telemetry wrappers using Eta.Tracer;
- redacted API-key handling.

Core does not provide:

- preflight token counting;
- eta_schema-generated provider schemas;
- public Eta_stream.Stream streaming;
- live OpenAI, Anthropic, OpenRouter, or OpenAI-compatible clients.

## Provider Shape

A provider is a value. Endpoint fields are data; JSON envelopes remain
provider-local functions.

    open Eta_ai

    let provider =
      {
        name = "fixture";
        base_url = "https://api.fixture.test";
        chat_path = "/v1/responses";
        embeddings_path = None;
        auth_headers =
          (fun key ->
            Eta_http.Core.Header.of_list
              [
                ("Authorization", "Bearer " ^ Eta_redacted.value key);
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
            embeddings = false;
            image_generation = false;
            speech = false;
            transcription = false;
            rerank = false;
            video_generation = false;
          };
        encode_chat = (fun _request -> Ok "{\"fixture\":true}");
        decode_chat =
          (fun raw ->
            Ok
              {
                id = Some "chatcmpl_fixture";
                model = Some "fixture-model";
                message =
                  Assistant { content = [ Text "done" ]; tool_calls = [] };
                finish_reasons = [ Stop ];
                usage =
                  Some
                    {
                      input_tokens = Some 3;
                      output_tokens = Some 5;
                      total_tokens = Some 8;
                      raw = [];
                    };
                raw = Some raw;
              });
        encode_embeddings =
          (fun _request ->
            Error (Unsupported { provider = "fixture"; feature = "embeddings" }));
        decode_embeddings =
          (fun _raw ->
            Error (Unsupported { provider = "fixture"; feature = "embeddings" }));
        decode_stream_event =
          (fun event ->
            match event.data with
            | "[DONE]" -> Ok [ Stream_done ]
            | data -> Ok [ Stream_content_delta data ]);
        decode_error =
          (fun ~status ~headers:_ raw ->
            Provider_error
              {
                provider = "fixture";
                status = Some status;
                code = None;
                message = "provider error";
                raw = Some raw;
              });
      }

The provider does not hold an HTTP client, runtime, switch, or application
state. Those remain outside eta_ai core.

## Redacted Keys

Use eta_ai's constructor for provider keys:

    let key = Eta_ai.api_key "sk-live-..."

The value type is string Eta_redacted.t. It cannot be passed to print_endline
as a string, and Eta_redacted.pp renders:

    <redacted:api_key>

Provider auth code may unwrap the key only at the HTTP header boundary.

## Tools

Tool schemas are raw JSON Schema text in v1.

    let weather =
      Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
        ~input_schema_json:
          "{"type":"object","required":["location"],"properties":{"location":{"type":"string"}}}"
        ~strict:true ()

    let tools =
      match weather with
      | Error error -> Error error
      | Ok tool -> Eta_ai.add_tool tool Eta_ai.empty_toolkit

The registry preserves registration order and rejects duplicate tool names.
It does not validate JSON Schema. That waits for eta_schema JSON Schema export.

## Chat

eta_ai core represents a chat request, then provider packages decide how to
encode and submit it.

    let request =
      {
        model = "fixture-model";
        prompt = [ System "stay brief"; User [ Text "hello" ] ];
        tools = [];
        temperature = Some 0.2;
        max_output_tokens = Some 64;
        stream = false;
      }

    let chat_effect =
      match provider.encode_chat request with
      | Error error -> Eta.Effect.fail error
      | Ok raw -> (
          match provider.decode_chat raw with
          | Ok response -> Eta.Effect.pure response
          | Error error -> Eta.Effect.fail error)

    let instrumented =
      Eta_ai.with_chat_span provider request chat_effect

Provider packages will replace the fixture encode/decode shortcut with an
eta_http request. The provider transport subtree should be wrapped in
Eta_ai.suppress_provider_transport_observability by default.

## OpenAI Provider Example

eta_ai_openai turns the same core request into an eta_http call. The API key is
redacted at the eta_ai boundary, while the eta_http client remains an ordinary
application dependency.

    let run_openai ~client =
      let api_key =
        match Sys.getenv_opt "OPENAI_API_KEY" with
        | Some value -> Eta_ai.api_key value
        | None -> failwith "OPENAI_API_KEY is required"
      in
      let request =
        {
          Eta_ai.model = "gpt-4o-mini";
          prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
          tools = [];
          temperature = Some 0.2;
          max_output_tokens = Some 64;
          stream = false;
        }
      in
      Eta_ai_openai.responses client ~api_key request

The explicit legacy Chat Completions runner uses the same Eta_ai.chat_request
value, but it is not the default OpenAI provider path:

    let run_openai_legacy_chat ~client ~api_key request =
      Eta_ai_openai.chat_completions client ~api_key request

For streaming Responses, request a stream and then pull provider events:

    let read_openai_stream ~client ~api_key request =
      Eta_ai_openai.stream_responses client ~api_key request
      |> Eta.Effect.bind Eta_ai.read_stream_events

## OpenAI-Compatible Provider Example

eta_ai_openai_compat owns a local OpenAI-compatible codec and eta_http runners
for providers that speak the OpenAI Chat Completions wire shape but use a
different base URL or auth header.

    let run_together ~client =
      let api_key =
        match Sys.getenv_opt "TOGETHER_API_KEY" with
        | Some value -> Eta_ai.api_key value
        | None -> failwith "TOGETHER_API_KEY is required"
      in
      let provider =
        Eta_ai_openai_compat.provider
          ~name:"together"
          ~base_url:"https://api.together.xyz"
          ()
      in
      let request =
        {
          Eta_ai.model = "meta-llama/Llama-3.3-70B-Instruct-Turbo";
          prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
          tools = [];
          temperature = Some 0.2;
          max_output_tokens = Some 64;
          stream = false;
        }
      in
      Eta_ai_openai_compat.chat_completions
        ~provider client ~api_key request

For providers that do not use bearer auth, choose a raw API-key header:

    let provider =
      Eta_ai_openai_compat.provider
        ~name:"internal-compatible"
        ~base_url:"https://llm.internal.example"
        ~auth:(Eta_ai_openai_compat.raw_header_auth ~header:"X-API-Key" ())
        ()

## OpenRouter Provider Example

eta_ai_openrouter uses the OpenAI-style Responses API envelope, plus
OpenRouter routing, attribution headers, fallback chains, and top-level or
mid-stream provider errors.

    let run_openrouter ~client =
      let api_key =
        match Sys.getenv_opt "OPENROUTER_API_KEY" with
        | Some value -> Eta_ai.api_key value
        | None -> failwith "OPENROUTER_API_KEY is required"
      in
      let attribution =
        Eta_ai_openrouter.attribution
          ~referer:"https://example.com"
          ~title:"Eta example"
          ()
      in
      let provider = Eta_ai_openrouter.provider ~attribution () in
      let routing =
        Eta_ai_openrouter.routing
          ~order:[ "anthropic"; "openai" ]
          ~allow_fallbacks:true
          ()
      in
      let request =
        {
          Eta_ai.model = "openrouter/auto";
          prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
          tools = [];
          temperature = Some 0.2;
          max_output_tokens = Some 64;
          stream = false;
        }
      in
      match routing with
      | Error error -> Eta.Effect.fail error
      | Ok routing ->
          Eta_ai_openrouter.responses
            ~provider ~routing client ~api_key request

## Anthropic Provider Example

eta_ai_anthropic uses the same Eta_ai.chat_request vocabulary, but encodes it
as an Anthropic Messages API request with top-level system text, content
blocks, x-api-key authentication, anthropic-version, and max_tokens.

    let run_anthropic ~client =
      let api_key =
        match Sys.getenv_opt "ANTHROPIC_API_KEY" with
        | Some value -> Eta_ai.api_key value
        | None -> failwith "ANTHROPIC_API_KEY is required"
      in
      let request =
        {
          Eta_ai.model = "claude-3-5-sonnet-latest";
          prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
          tools = [];
          temperature = Some 0.2;
          max_output_tokens = Some 64;
          stream = false;
        }
      in
      Eta_ai_anthropic.messages client ~api_key request

Prompt caching is request-local:

    let run_anthropic_cached ~client ~api_key request =
      let prompt_cache =
        Eta_ai_anthropic.prompt_cache ~cache_system:true ()
      in
      Eta_ai_anthropic.messages ~prompt_cache client ~api_key request

Streaming Anthropic Messages uses named SSE events internally but returns the
same eta_ai stream events:

    let read_anthropic_stream ~client ~api_key request =
      Eta_ai_anthropic.stream_messages client ~api_key request
      |> Eta.Effect.bind Eta_ai.read_stream_events

## Streaming

AC3 exposes an eta_http-backed pull parser. It is intentionally not an
Eta_stream.Stream yet.

    let body =
      Eta_http.Body.Stream.of_bytes
        [
          Bytes.of_string "data: hello\n\n";
          Bytes.of_string "data: [DONE]\n\n";
        ]

    let stream = Eta_ai.stream_of_body provider body

    let read_all =
      Eta_ai.read_stream_events stream
      |> Eta_ai.with_stream_span provider { request with stream = true }

The parser owns SSE framing and eta_http body discard. Provider-specific JSON
events stay inside provider.decode_stream_event.

## Tool Execution

Tool execution is application code. eta_ai only provides the common span shape.

    let run_weather _args =
      Eta.Effect.pure "{"temperature":21}"
      |> Eta_ai.with_tool_span ~tool_call_id:"call_weather"
           ~tool_name:"weather"

When this runs inside a chat span, the tool span is an internal child span.
Tool arguments and results are not recorded by default.

## Gates

Run the package gate after changing eta_ai core:

    bash lib/ai/audit/run.sh
    nix develop -c dune runtest test/ai/core --force
    nix develop -c dune build
    nix develop -c eta-oxcaml-test-shipped

Run the OpenAI provider gate after changing eta_ai_openai:

    bash lib/ai/openai/audit/run.sh
    nix develop -c dune runtest test/ai/openai --force

Run the Anthropic provider gate after changing eta_ai_anthropic:

    bash lib/ai/anthropic/audit/run.sh
    nix develop -c dune runtest test/ai/anthropic --force

Run the OpenAI-compatible provider gate after changing
eta_ai_openai_compat:

    bash lib/ai/openai_compat/audit/run.sh
    nix develop -c dune runtest test/ai/openai_compat --force

Run the OpenRouter provider gate after changing eta_ai_openrouter:

    bash lib/ai/openrouter/audit/run.sh
    nix develop -c dune runtest test/ai/openrouter --force
