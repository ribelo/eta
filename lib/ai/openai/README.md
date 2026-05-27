# eta-ai-openai

OpenAI provider package for eta-ai.

This package constructs eta-ai provider values and eta-http request runners for
OpenAI Responses API requests, explicit legacy Chat Completions compatibility,
function tools, structured output schemas, and SSE streaming.

It has no dependency on OpenAI SDKs, generated clients, or tokenizer
libraries. Provider-specific JSON is encoded and decoded against
recorded offline fixtures. Live provider reach is a release gate, not a
per-commit test, because it requires an API key.

## Configuration

Use eta-ai redacted keys and pass eta-http clients explicitly:

    let api_key =
      match Sys.getenv_opt "OPENAI_API_KEY" with
      | Some value -> Eta_ai.api_key value
      | None -> failwith "OPENAI_API_KEY is required"

    let request =
      {
        Eta_ai.model = "gpt-4o-mini";
        prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
        tools = [];
        temperature = Some 0.2;
        max_output_tokens = Some 64;
        stream = false;
      }

    let effect =
      Eta_ai_openai.responses client ~api_key request

Use the explicit legacy provider only when a target still requires the Chat
Completions wire shape:

    let provider =
      Eta_ai_openai.chat_completions_provider
        ~base_url:"https://api.openai.example"
        ()

Prefer eta-ai-openai-compat for non-OpenAI services with configurable auth or
base-path behavior.

## API Coverage

- Responses API: input messages, function tools, raw JSON structured outputs,
  streaming flag, temperature, and max_output_tokens.
- Explicit legacy Chat Completions: messages, function tools, raw JSON
  structured outputs, streaming flag, temperature, and max_tokens.
- Streaming: OpenAI chat completion chunks, Responses output text deltas,
  function-call argument deltas, done markers, and error events.
- Errors: OpenAI error objects are decoded into Eta_ai.Provider_error with
  status, code, message, and raw body.

## Quirks

- Tool schemas and structured-output schemas are raw JSON text until eta-schema
  exposes JSON Eta_schema export.
- Token counting is intentionally absent. Use provider usage fields from
  responses.
- The default provider uses the Responses endpoint. The legacy Chat
  Completions encoder uses max_tokens when called explicitly.
- Provider HTTP calls are wrapped in
  Eta_ai.suppress_provider_transport_observability by default so eta-http spans
  do not nest under GenAI spans unless an application deliberately adds them.
- Offline fixtures prove codec and eta-http integration behavior. They do not
  prove current OpenAI service behavior; run the release reach probe when an API
  key is available.

Run:

    bash lib/ai/openai/audit/run.sh
    nix develop -c dune runtest lib/ai/openai --force
