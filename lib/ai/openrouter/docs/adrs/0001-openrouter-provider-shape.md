# ADR 0001: OpenRouter Provider Shape

## Status

Accepted for the offline AP4 implementation. Live OpenRouter canary reach has
passed; fixture refresh remains a deliberate release step.

## Context

OpenRouter follows an OpenAI-style Responses API envelope but adds provider
routing controls, attribution headers, fallback behavior, and top-level or
mid-stream provider error shapes. Those additions are not generic eta-ai core
features.

The provider-package dependency policy also rules out depending on a sibling
provider package. AP4 can echo the Responses envelope, but it must own the
OpenRouter-specific request, decode, and runner code locally while depending
only on eta, eta-ai, eta-redacted, and eta-http.

## Decision

eta-ai-openrouter exports:

- a default OpenRouter provider value for https://openrouter.ai and
  /api/v1/responses plus /api/v1/embeddings;
- optional HTTP-Referer and X-Title attribution headers;
- request-local routing controls encoded under the provider JSON object;
- local Responses-style input, tool, structured-output, response, SSE, and
  error codecs;
- local Embeddings-style input, usage, float-vector, and base64-vector codecs;
- unified Chat and Embeddings modules that include Eta_ai.Provider interfaces
  and extend them with OpenRouter routing helpers;
- eta-http request runners that suppress nested transport spans under eta-ai
  GenAI spans.

OpenRouter routing remains request-local because fallback chains and provider
selection are call-specific policy, not global runtime state.

## Evidence

Offline fixture tests cover:

- auth, attribution, and extra headers;
- routing JSON and invalid empty provider names;
- structured-output text.format construction;
- OpenRouter endpoint construction through eta-http requests;
- OpenRouter embeddings endpoint construction and fixture decoding;
- text and tool-call response fixtures;
- top-level/mid-stream OpenRouter error chunks;
- suppression of nested eta-http transport spans under the GenAI chat span.

Focused command:

    bash lib/ai/openrouter/audit/run.sh
    nix develop -c dune runtest lib/ai/openrouter --force

The previous canary reached OpenRouter with openai/gpt-4o-mini through
eta-http. The preserved verdict is
`docs/research/evidence/eta_ai_v1/probes/live_reach/verdict.md`. Recreate the
local probe before release if live canary coverage is needed.

## Consequences

- AP4 keeps OpenRouter routing and provider-error behavior out of eta-ai core.
- AP4 has no sibling provider-package dependency.
- Offline fixtures are not proof of current OpenRouter service behavior by
  themselves. Keep the canary as release evidence and refresh fixtures
  deliberately when provider behavior changes.
