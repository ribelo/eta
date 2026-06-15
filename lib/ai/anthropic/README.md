# eta_ai_anthropic

Anthropic provider package for eta_ai.

This package constructs eta_ai provider values and eta_http request runners for
Anthropic Messages API requests, tool use, SSE streaming, provider usage fields,
and prompt-cache controls.

It has no dependency on Anthropic SDKs, generated clients, or tokenizer
libraries. Provider-specific JSON is encoded and decoded against
recorded offline fixtures. Live provider reach is a release gate, not a
per-commit test, because it requires an API key.

## Package boundary

- `eta_ai_anthropic` depends on `eta`, `eta_ai`, `eta_redacted`, `eta_http`, and
  `yojson`.
- It does not depend on sibling provider packages or the Anthropic SDK.
- It does not pull `eta_http_eio`; use `Eta_http_eio.Client` to build the HTTP
  client you pass in.

## Configuration

Use eta_ai redacted keys and pass eta_http clients explicitly:

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

Prompt caching is request-local in eta_ai_anthropic:

    let prompt_cache =
      Eta_ai_anthropic.prompt_cache ~cache_system:true ()

    let effect =
      Eta_ai_anthropic.messages ~prompt_cache client ~api_key request

This adds the Anthropic beta header and encodes system text as a text block with
an ephemeral cache_control object. eta_ai's current message vocabulary does not
attach cache metadata to arbitrary content blocks.

## Quirks

- Anthropic requires max_tokens. eta_ai_anthropic rejects requests with
  max_output_tokens = None.
- System prompts are top-level, not messages.
- Tool definitions use input_schema, not OpenAI's function.parameters.
- Tool results are user content blocks of type tool_result.
- Token counting is intentionally absent. Use provider usage fields from
  responses.
- Offline fixtures prove codec and eta_http integration behavior. They do not
  prove current Anthropic service behavior; run the release reach probe when an
  API key is available.

Run:

    bash lib/ai/anthropic/audit/run.sh
    nix develop -c dune runtest test/ai/anthropic --force
