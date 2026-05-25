# ADR 0001: Provider Values

Status: accepted.

## Context

eta-ai needs one common provider boundary for OpenAI, Anthropic,
OpenAI-compatible providers, and OpenRouter.

A1 found shared concerns that are data fields: provider name, base URL, chat
path, auth headers, and capability flags. It also found structural differences
that are not just field renames: Anthropic request envelopes, tool result
blocks, named SSE events, and OpenRouter mid-stream errors.

The boundary must preserve Eta's ownership rule: applications own state;
eta-ai owns effect description and interpretation. Provider packages may
construct values, but they must not own application runtime state.

## Decision

eta-ai exposes a provider as a record value:

    type provider = {
      name : provider_name;
      base_url : string;
      chat_path : string;
      auth_headers : api_key -> headers;
      capabilities : capabilities;
      encode_chat : chat_request -> (raw_json, ai_error) result;
      decode_chat : raw_json -> (response, ai_error) result;
      decode_stream_event : sse_event -> (stream_event list, ai_error) result;
      decode_error : status:int -> headers:headers -> raw_json -> ai_error;
    }

api_key is string Redacted.t. The provider auth boundary is public API, so
it starts with the redacted key shape required by AC6 instead of accepting
plain strings and changing later.

encode_chat returns a result because provider encoders are the first place that
can reject an unsupported common feature, such as tools on a minimal provider.

## Rejected

- Data-only providers. Anthropic and OpenRouter require provider-local codecs.
- Provider modules or functors as the first public shape. A1 did not find
  provider-specific runtime ownership or control flow that needs modules.
- Public Stream.Stream streaming in AC2. A2 showed eta-http can provide
  body chunks, but eta-stream still needs an owned effect-reader source before
  eta-ai exposes stream ownership publicly.

## Consequences

- Provider packages should mostly construct Ai.provider values.
- Provider-specific JSON remains behind encode/decode functions.
- Common eta-ai code can inspect endpoint fields and capability flags without
  knowing provider-specific envelopes.
- Public streaming remains a tagged event decoder shape until AC3 resolves the
  eta-stream source primitive dependency.

## Evidence

- scratch/eta_ai_v1/probes/provider_diff/verdict.md
- .objectives/eta-ai-shape-decision.md
- packages/eta-ai/test/test_eta_ai.ml

## Verification

    nix develop -c dune runtest packages/eta-ai --force
    nix develop -c dune build
    nix develop -c eta-oxcaml-test-shipped
