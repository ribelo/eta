# eta-ai-anthropic

Anthropic provider package for eta-ai.

This package constructs eta-ai provider values and eta-http request runners for
Anthropic Messages API requests, tool use, SSE streaming, provider usage fields,
and prompt-cache controls.

It has no dependency on Anthropic SDKs, generated clients, or tokenizer
libraries. Provider-specific JSON is encoded and decoded against
recorded offline fixtures. Live provider reach is a release gate, not a
per-commit test, because it requires an API key.

## Configuration

Use eta-ai redacted keys and pass eta-http clients explicitly:

    let api_key =
      match Sys.getenv_opt "ANTHROPIC_API_KEY" with
      | Some value -> Eta_ai.api_key value
      | None -> failwith "ANTHROPIC_API_KEY is required"

    let request =
      {
        Eta_ai.model = "claude-3-5-sonnet-latest";
        prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
        tools = [];
        temperature = Some 0.2;
        max_output_tokens = Some 64;
        stream = false;
      }

    let effect =
      Eta_ai_anthropic.messages client ~api_key request

Override the API version only when Anthropic changes the required
anthropic-version header:

    let provider =
      Eta_ai_anthropic.provider ~version:"2023-06-01" ()

## Prompt Caching

Prompt caching is request-local in eta-ai-anthropic:

    let prompt_cache =
      Eta_ai_anthropic.prompt_cache ~cache_system:true ()

    let effect =
      Eta_ai_anthropic.messages ~prompt_cache client ~api_key request

This adds the Anthropic beta header and encodes system text as a text block with
an ephemeral cache_control object. eta-ai's current message vocabulary does not
attach cache metadata to arbitrary content blocks.

## Quirks

- Anthropic requires max_tokens. eta-ai-anthropic rejects requests with
  max_output_tokens = None.
- System prompts are top-level, not messages.
- Tool definitions use input_schema, not OpenAI's function.parameters.
- Tool results are user content blocks of type tool_result.
- Token counting is intentionally absent. Use provider usage fields from
  responses.
- Offline fixtures prove codec and eta-http integration behavior. They do not
  prove current Anthropic service behavior; run the release reach probe when an
  API key is available.

Run:

    bash packages/eta-ai-anthropic/audit/run.sh
    nix develop -c dune runtest packages/eta-ai-anthropic --force
