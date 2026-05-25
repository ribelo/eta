# ADR 0001: OpenAI-Compatible Provider Shape

## Status

Accepted for the offline AP3 implementation. Live reach remains a release gate
per compatible provider.

## Context

Phase A-R found that OpenAI-compatible APIs are a compatibility profile, not one
provider. They usually share OpenAI's Chat Completions request, response, tool,
streaming, and error shapes, but vary base URL, path, auth header policy, model
IDs, limits, and extra headers.

AP3 should prove that the AP1 provider shape can be reused when the differences
are data, while preserving the provider-package dependency policy: provider
packages depend on eta-ai and eta-http, not on each other.

## Decision

eta-ai-openai-compat exports a configurable provider wrapper:

- base_url is required.
- chat_path defaults to /v1/chat/completions.
- auth defaults to Authorization: Bearer <api_key>.
- raw-header auth is available for providers that expect an unprefixed key.
- extra_headers are appended to the provider's auth headers.
- Chat, streaming, structured-output, decoding, and error behavior use a local
  OpenAI-compatible codec with the same eta-ai response vocabulary.

The runner functions require an explicit provider value. This avoids implying
that there is a single default OpenAI-compatible service.

## Evidence

Offline fixture tests cover:

- Together-style bearer auth and base URL configuration;
- Mistral-style base URL plus extra headers;
- raw-header auth for private compatible endpoints;
- OpenAI-compatible request body construction through the local codec;
- structured-output response_format construction through the local codec;
- text and tool-call fixture decoding through the local codec;
- streaming fixture decoding through the local codec;
- provider error decoding through the local codec;
- suppression of nested eta-http transport spans under the GenAI chat span.

Focused command:

    nix develop -c dune runtest packages/eta-ai-openai-compat --force

## Consequences

- eta-ai plus eta-http are sufficient for AP3's supported compatibility
  profile; no sibling provider package dependency is needed.
- OpenRouter is intentionally excluded from AP3 because AP4 owns routing and
  OpenRouter-specific headers/errors.
- Offline fixtures are not proof of broad compatibility. AP3 should not claim
  a named provider until a canary reach probe runs with that provider's key and
  the fixture corpus is refreshed from that interaction.
