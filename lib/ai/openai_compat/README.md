# eta-ai-openai-compat

OpenAI-compatible provider package for eta-ai.

This package constructs configurable eta-ai provider values for services that
speak the OpenAI Chat Completions wire shape but require a provider-specific
base URL, path, auth header, or extra headers.

It owns a small local OpenAI-compatible codec and eta-http runners. It has no
dependency on sibling provider packages, provider SDKs, generated clients, or
tokenizer libraries. Offline fixtures prove wrapper behavior only;
live provider reach is a release gate for each target provider.

## Configuration

Use eta-ai redacted keys and pass eta-http clients explicitly:

    let api_key =
      match Sys.getenv_opt "TOGETHER_API_KEY" with
      | Some value -> Eta_ai.api_key value
      | None -> failwith "TOGETHER_API_KEY is required"

    let provider =
      Eta_ai_openai_compat.provider
        ~name:"together"
        ~base_url:"https://api.together.xyz"
        ()

    let request =
      {
        Eta_ai.model = "meta-llama/Llama-3.3-70B-Instruct-Turbo";
        prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
        tools = [];
        temperature = Some 0.2;
        max_output_tokens = Some 64;
        stream = false;
      }

    let effect =
      Eta_ai_openai_compat.chat_completions ~provider client ~api_key request

Use raw-header auth only for providers that do not use bearer auth:

    let provider =
      Eta_ai_openai_compat.provider
        ~name:"internal-compatible"
        ~base_url:"https://llm.internal.example"
        ~auth:(Eta_ai_openai_compat.raw_header_auth ~header:"X-API-Key" ())
        ()

## Quirks

- This package assumes the provider accepts OpenAI Chat Completions JSON.
- Provider-specific model names, limits, tool support, and structured-output
  support remain provider behavior, not eta-ai guarantees.
- OpenRouter is intentionally not represented here because AP4 owns routing and
  OpenRouter-specific headers/errors.

Run:

    bash lib/ai/openai_compat/audit/run.sh
    nix develop -c dune runtest lib/ai/openai_compat --force
