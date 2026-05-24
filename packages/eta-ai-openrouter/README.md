# eta-ai-openrouter

OpenRouter provider package for eta-ai.

This package constructs eta-ai provider values and eta-http request runners for
OpenRouter Responses API requests, routing controls, fallback chains,
attribution headers, and provider-specific errors.

It owns OpenRouter-specific behavior around the Responses envelope:
provider routing objects, `HTTP-Referer`/`X-Title` attribution headers, and
mid-stream/top-level error decoding. It has no dependency on sibling provider
packages, provider SDKs, generated clients, or tokenizer libraries.

## Configuration

Use eta-ai redacted keys and pass eta-http clients explicitly:

    let api_key =
      match Sys.getenv_opt "OPENROUTER_API_KEY" with
      | Some value -> Eta_ai.api_key value
      | None -> failwith "OPENROUTER_API_KEY is required"

    let attribution =
      Eta_ai_openrouter.attribution
        ~referer:"https://example.com"
        ~title:"Eta example"
        ()

    let provider =
      Eta_ai_openrouter.provider ~attribution ()

    let routing =
      Eta_ai_openrouter.routing
        ~order:[ "anthropic"; "openai" ]
        ~allow_fallbacks:true
        ()

    let request =
      {
        Eta_ai.model = "openrouter/auto";
        prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
        tools = [];
        temperature = Some 0.2;
        max_output_tokens = Some 64;
        stream = false;
      }

    let effect =
      match routing with
      | Error error -> Eta.Effect.fail error
      | Ok routing ->
          Eta_ai_openrouter.responses
            ~provider ~routing client ~api_key request

## Quirks

- OpenRouter routing is request-local and encoded under the `provider` JSON
  object.
- Ordered `routing.order` models a fallback chain.
- OpenRouter may emit mid-stream errors as ordinary data frames with a top-level
  `error` object; these become `Eta_ai.Stream_error` events.
- Offline fixtures prove codec and eta-http integration behavior. They do not
  prove current OpenRouter service behavior; run the release reach probe when an
  API key is available.

Run:

    bash packages/eta-ai-openrouter/audit/run.sh
    nix develop -c dune runtest packages/eta-ai-openrouter --force
