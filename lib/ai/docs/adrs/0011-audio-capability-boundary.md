# ADR 0011: Audio Capability Boundary

Status: accepted.

## Context

Eta AI originally exposed audio through two thin neutral records, `Eta_ai.Speech`
and `Eta_ai.Transcription`, shaped by the smallest common denominator of the
providers that existed when they were added. The current OpenAI audio product is
much larger: discriminated built-in and custom voices, three transcription
response formats, streamed transcript events, batch translation, Chat audio
output, three distinct Realtime protocols, and restricted consent and
custom-voice resources. xAI's audio surface is comparably large and differently
shaped.

Two failure modes were available. Widening the neutral records until every
provider field fits would produce records whose valid combinations are known only
to each provider. Keeping providers fully independent would duplicate the genuine
shared concepts and invite pairwise provider coupling.

## Decision

`Eta_ai.Audio` owns provider-neutral audio vocabulary and nothing else. It holds
the minimal request and result subsets that OpenAI and xAI genuinely share, the
neutral upload source used for audio uploads, and module types describing shared
audio lifecycle contracts. `Eta_ai.Speech` and `Eta_ai.Transcription` are
deleted; `Audio` replaces them in the capability-module list.

Each first-class audio provider keeps full-fidelity request, response, session,
event, voice, and error types. Providers convert from the neutral request subset
into their own request construction and project their results back into the
neutral subset explicitly. Conversion from neutral data yields a value that still
requires provider-specific configuration before a submittable request exists, so
neither an optional-field soup nor a silent provider default can produce an
invalid request.

OpenAI and xAI expose the same audio topology: `Audio.Speech_to_text`,
`Audio.Text_to_speech`, `Audio.Voices`, and `Audio.Realtime`, with
provider-specific children beneath. Shared shapes are module types that providers
`include ... with type ...`, as `Eta_ai.Realtime.Codec` already does. Eta does
not use functors here: no functor body could be written generically over
non-interchangeable provider types, instantiation would add ceremony at every
call site, and generative identity would let two instantiations of the same
provider produce incompatible types.

xAI migrates onto the shared vocabulary in the same change that introduces it,
and xAI-local structures the shared vocabulary displaces are deleted.

## Rejected

- Widen `Eta_ai.Speech` and `Eta_ai.Transcription` until every OpenAI and xAI
  field fits. This encodes provider-invalid states in a neutral type.
- Keep provider-only audio types with direct OpenAI to xAI conversions. This
  couples providers pairwise and duplicates real shared concepts.
- Functorize the audio seam. It buys no genuine abstraction over provider types
  and imposes instantiation identity problems on applications.
- Add the seam for OpenAI now and migrate xAI later. A shared abstraction with
  one implementation is unproven.
- Retain the old neutral modules as aliases during migration. Eta does not carry
  migration paths inside the library.

## Consequences

- Applications gain one neutral audio vocabulary for cross-provider code and keep
  complete provider fidelity when they need it.
- Provider audio APIs change in a breaking way, and all callers and tests are
  updated in the same change.
- Every audio provider is navigable through the same module topology even where
  the enclosed types differ.
- New provider audio fields land in provider types first, and reach the neutral
  subset only when a second provider genuinely shares them.

## Evidence

- `docs/requirements/eta-ai-openai-audio/cross-provider.md`
- `docs/requirements/eta-ai-openai-audio/package-boundary.md`
- `docs/requirements/eta-maintainability/ai-module-organization.md`
- ADR 0006 for the equivalent Responses request decision.
