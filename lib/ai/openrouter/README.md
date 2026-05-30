# eta-ai-openrouter

OpenRouter provider package for eta-ai.

This package constructs eta-ai provider values and eta-http request runners for
OpenRouter Responses API, Embeddings API, rerank, speech, transcription, video
generation, routing controls, fallback chains, attribution headers, and
provider-specific errors.

It owns OpenRouter-specific behavior around Responses and Embeddings envelopes:
provider routing objects, `HTTP-Referer`/`X-Title` attribution headers,
embedding input and vector codecs, and mid-stream/top-level error decoding. It
has no dependency on sibling provider packages, provider SDKs, generated
clients, or tokenizer libraries.

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

    let embeddings =
      {
        Eta_ai.Embedding.model = "openai/text-embedding-3-small";
        input = Eta_ai.Embedding.Text "weather in Warsaw";
        encoding_format = Some "float";
        dimensions = Some 1536;
        user = None;
      }

    let embedding_effect =
      Eta_ai_openrouter.Embeddings.run_with_routing
        ~provider ~routing client ~api_key embeddings

## Quirks

- OpenRouter routing is request-local and encoded under the `provider` JSON
  object.
- Provider packages expose unified `Chat`, `Embeddings`, `Speech`,
  `Transcriptions`, `Rerank`, and `Video` modules that include the common
  `Eta_ai.Provider` interfaces; OpenRouter extends chat and embeddings with
  routing and Responses-specific helpers.
- Ordered `routing.order` models a fallback chain.
- Embeddings use `POST /api/v1/embeddings` and decode both float-vector and
  base64 embedding entries.
- Speech uses `POST /api/v1/audio/speech` and returns binary audio bytes.
- Transcriptions use OpenRouter's JSON `input_audio` request shape with
  base64-encoded audio.
- Rerank uses `POST /api/v1/rerank`.
- Video generation supports job creation, polling, and generated content
  downloads through `/api/v1/videos`.
- OpenRouter may emit mid-stream errors as ordinary data frames with a top-level
  `error` object; these become `Eta_ai.Stream_error` events.
- Offline fixtures prove codec and eta-http integration behavior. They do not
  prove current OpenRouter service behavior; run the release reach probe when an
  API key is available.

Run:

    bash lib/ai/openrouter/audit/run.sh
    nix develop -c dune runtest lib/ai/openrouter --force
