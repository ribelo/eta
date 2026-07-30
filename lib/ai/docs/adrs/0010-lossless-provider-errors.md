# ADR 0010: Lossless provider-owned errors

## Context

Eta's original first-class AI providers returned `Eta_ai.ai_error` directly.
That neutral error is useful to applications that want one failure vocabulary,
but it collapses response headers and provider-specific structured fields.
OpenAI, Anthropic, OpenRouter, Kimi Coding, Moonshot, and OpenAI Codex therefore
lose actionable information at the provider boundary. The dynamic
OpenAI-compatible adapter also loses transport facts even though it cannot know
the configured provider's schema. xAI already demonstrates the desired shape:
a lossless nominal error with an explicit neutral projection.

## Decision

Every first-class transport-neutral provider package owns one nominal error type
across all of its public fallible operations. This includes validation, codecs,
request construction, transport, provider HTTP failures, and streaming. The old
parallel operations returning `Eta_ai.ai_error` are removed rather than retained
as compatibility aliases.

`Eta_ai.Provider.Error` owns only the common lossless HTTP-response envelope:
status, headers, an optional provider-decoded payload, and the raw response body.
Each provider owns its payload schema and complete error sum. This shares stable
transport facts without pretending provider error protocols are equivalent.

OpenAI preserves message, type, parameter, and code without coercing parameter
or code values to strings. Anthropic preserves its top-level and nested error
types and request identity. OpenRouter preserves routing metadata and nested
upstream response errors. Kimi Coding and Moonshot own separate types despite
sharing compatible inference codecs. OpenAI Codex uses one sum type across its
inference and OAuth workflow. The dynamic compatibility adapter preserves a
configured provider name and lossless response envelope without claiming a
provider-specific payload schema. xAI retains its existing nominal error.

Every nominal error exposes a total, explicit projection to
`Eta_ai.ai_error`. Loss of provider-specific information is allowed only at that
projection boundary. `eta_ai_openai_codec` remains a wire-codec package and does
not choose the public nominal type of its callers.

## Rejected

- Keep `Eta_ai.ai_error` as every provider's public error. This discards facts at
  the point where they are most useful.
- Reuse one provider's nominal type in another provider. Wire compatibility does
  not establish error-contract ownership.
- Use one fully generic nominal provider error. This merely moves the lossy
  abstraction behind a new type name.
- Change only network runners. Mixed error channels make callers track which
  implementation layer rejected an operation.

## Consequences

- Provider API changes are intentionally breaking and require all callers and
  tests to migrate.
- Applications can retain complete provider failures or project explicitly into
  a neutral cross-provider vocabulary.
- Shared transport and codec helpers must be polymorphic in the provider error
  chosen by their caller.
- Exact provider payload schemas require first-party contract research before
  implementation.
