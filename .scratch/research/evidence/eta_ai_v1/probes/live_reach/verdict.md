# Provider live reach verdict

Status: accepted with account/product/billing caveats.

Decision:

- eta-http is sufficient for live provider HTTPS calls after initializing the
  Mirage crypto RNG inside the eta-http TLS transport path.
- The shipped eta-ai provider package shape is live-validated for Anthropic,
  OpenRouter, Mistral, Groq, DeepSeek, Novita, and Perplexity in this
  environment.
- OpenAI successful paid completion remains a reopener because the available
  account has no credit; the canary still proved OpenAI reach and typed
  provider-error handling in this environment.
- Kimi Code, Z.ai, and Moonshot reached provider APIs but remain reopeners due
  to product-scope or billing/resource state.
- Together and Fireworks remain reopeners because accounts are absent.

Evidence:

- The first live run reached no provider payloads and failed all HTTPS calls
  with Mirage_crypto_rng's uninitialized default generator error.
- `lib/http_eio/transport/connect.ml` now initializes the process-wide
  Mirage crypto RNG before TLS handshakes and maps initialization failure into
  eta-http's typed TLS error channel.
- The filtered live reach canary passed for Anthropic after choosing
  claude-haiku-4-5-20251001 from the live Anthropic model list.
- A full live canary run passed OpenRouter, Mistral, Groq, and DeepSeek,
  reached OpenAI with a typed provider error, and skipped Together/Fireworks
  because keys were missing.
- The expanded AP3 live run passed Groq, DeepSeek, Novita, and Perplexity;
  Kimi Code returned a product-scope 403, Z.ai returned insufficient resource
  state, and Moonshot returned insufficient balance.
- The canary redacts configured env-key values plus key-like sk-/ak- and org-
  tokens before printing provider error text or writing local scratch results.

Verification:

    bash .scratch/eta_ai_v1/probes/live_reach/run.sh anthropic

Disproof signature outcome:

- Triggered for eta-http transport setup: without the RNG fix, no provider
  could perform TLS handshakes through eta-http.
- Not triggered for the provider value shape: successful canaries all used the
  shipped provider packages over Http.Client.make.

Open release evidence:

- Re-run OpenAI if a funded OPENAI_API_KEY becomes available.
- Re-run Kimi Code from an allowed coding-agent context if that is required.
- Re-run Z.ai and Moonshot if billing/resource state becomes available.
- Re-run Together with TOGETHER_API_KEY.
- Re-run Fireworks with FIREWORKS_API_KEY.
