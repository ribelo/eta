# Eta — Post-HTTP Arc: eta-otel rebuild + eta-ai

Status: Complete under the currently available provider-account scope.
eta-http v1 closed. Eta-1yb prerequisite capabilities (Redacted, LogLevel,
MutableRef, Semaphore) are present in the current tree. Track O and Track A are
implemented to their current evidence levels; completion evidence and
provider-account reopeners are tracked in
.objectives/eta-otel-and-eta-ai-completion-audit.md.

This is the master objective. Lives in `.objectives/eta-otel-and-eta-ai.md`
per repo-hygiene convention; per-track research lands in `scratch/`; per-track
code lands in `packages/`.

---

## 0. Goal

Two tracks, both clean-room, both consuming eta-http v1.

**Track O — eta-otel rebuild.** Replace effet-otel's hand-rolled Eio plumbing
with an Eta-primitive-first implementation that POSTs OTLP/HTTP through
eta-http v1. Bounded scope. Closes the dogfood story.

**Track A — eta-ai.** New package family. Clean-room port of Effect AI's
intent for Eta. Foundation package + four provider sub-packages
(`eta-ai-openai`, `eta-ai-anthropic`, `eta-ai-openai-compat`,
`eta-ai-openrouter`). Research-driven design phase first (no code lands until
the API shape is settled by evidence), then implementation.

The Effect AI TypeScript reference is large because of TypeScript-specific
ceremony — DI scaffolding, generated OpenAPI clients, per-provider schema
duplication, type-system workarounds. **The research question is which of
those patterns are essence and which are ceremony.** The implementation that
follows is whatever shape the evidence justifies. We do not put a number on
the result; we put discipline on the process.

---

## 1. Constraints

### 1.1 Priority order

**correctness > DX > performance**

- **Correctness**: typed errors, schema-validated tool args where applicable,
  RFC-correct SSE parsing, exhaustive variant coverage, redacted secrets,
  preserved authorship of typed-failure shapes through the call stack.
- **DX**: composable, `|>`-friendly, OxCaml-idiomatic. Caller code reads
  naturally:

  The following is an example API, not the proposed final form. 
  ```ocaml
  prompt
  |> with_system "You are concise."
  |> with_user "Explain quantum computing in 30 words."
  |> Model.complete client model
  ```
- **Performance**: zero-allocation on hot paths *because we can*, not at the
  cost of DX or correctness. Audit the trade-offs honestly.

This priority order is non-negotiable. Performance work cannot bend
correctness; DX work cannot hide errors. The experimenter calibrates
trade-offs against this order, not against unstated metrics.

### 1.2 Clean-room

We do **not** copy code from Effect AI, openai-node,
anthropic-sdk-typescript, or any other reference. Read for shape; derive our
own implementation against:
- Provider OpenAPI specs / public API documentation
- HTTP / SSE / JSON RFCs
- Eta primitives (Pool, Channel, timeout_as, Stream, Capabilities, Tracer,
  Schedule, Resource, Redacted)

Same posture as eta-http v1 vs httpz/requests. Each line of Track O / Track A
source is written by us against the relevant spec.

### 1.3 Minimum deps

**eta-otel** depends on: `eta`, `eta-stream`, `eta-http`, transitive TLS stack
via eta-http, `decompress` (if OTLP gzip is in scope, gated by the eta-http
S3 transducer).

**eta-ai core** depends on: `eta`, `eta-redacted`, `eta-http`, plus
`eta-schema` only if the A3 schema-integration probe says it earns its place.
`eta-redacted` is the API-key redaction boundary; `Eta.Redacted` remains a
compatibility alias.

**Each provider package** depends on: `eta`, `eta-ai`, `eta-redacted`, and
`eta-http`. No additional deps.

**Rejected across both tracks**: `cohttp-eio`, anything Lwt-shaped,
`conpool`, raw HTTP client implementations, generated OpenAPI client
libraries.

If a slice surfaces a need to add a dep beyond this list, the experimenter
**stops and reports**. Adding deps is a planner decision.

### 1.4 Audit-from-day-one

Same Bun-style discipline as eta-http v1. Every package has:
- `audit/dep_usage.md` — every external dep call site, classified
  (structural / replaceable / debt) with replacement cost.
- `audit/eta_escapes.md` — every raw `Eio.Fiber.fork` / `Eio.Switch.run` /
  `Eio.Promise.*` / `Eio.Mutex` / `Eio.Condition` / non-`Atomic.Portable`
  `Atomic.t` site, classified.
- `audit/run.sh` — ripgrep+awk pipeline that updates timestamps and counts.

The audit catalogs are **not gates**; they are the truth-of-record. They tell
a future maintainer exactly where the library reaches into substrate vs Eta
primitives and what we considered structural vs replaceable.

### 1.5 Research lives in `scratch/`

Per user direction. Master objectives live under `.objectives/<name>.md`;
per-objective research probes live under `scratch/<topic>/`; production code
lives under `packages/<pkg>/`. ADRs co-locate with the package they govern at
`packages/<pkg>/docs/adrs/`.

### 1.6 Reference posture

Read for shape, **do not copy code**.

For Track O:
- `packages/eta-otel/` (existing effet-otel — do **not** mine; rebuild from
  scratch on eta-http).
- `.reference/effect-smol/packages/effect/src/unstable/ai/Telemetry.ts` —
  Effect's OTel attribute conventions.
- OpenTelemetry OTLP/HTTP JSON spec.

For Track A:
- `.reference/effect-smol/packages/effect/src/unstable/ai/` — AiError, Chat,
  EmbeddingModel, LanguageModel, Model, Prompt, Response, Telemetry,
  Tokenizer, Tool, Toolkit, IdGenerator. Read which problems exist; identify
  which patterns are TypeScript-DI scaffolding (`R` context, `Effect.gen`
  chains) vs domain essence.
- `.reference/effect-smol/packages/ai/{openai,anthropic,openai-compat,openrouter}/` —
  provider-specific surfaces. Identify which provider differences are data
  (URLs, headers, field names) vs structurally different (parsers, error
  shapes).
- Provider public docs + OpenAPI specs:
  - https://platform.openai.com/docs/api-reference
  - https://docs.anthropic.com/en/api/overview
  - https://openrouter.ai/docs

---

## 2. Track O — eta-otel rebuild

Bounded. Replace effet-otel with eta-otel built on Eta primitives + eta-http.
OTLP/HTTP wire shape unchanged. Existing effet-otel functional tests are the
regression gate.

Backlog: Eta-5zo (epic), Eta-yo4 (Phase R), Eta-331 (R-T0 transparent-cost),
Eta-xgg (R-T1 peer analysis), Eta-jxz (R-T2 OTLP capability inventory).

### 2.1 Concrete (port from prior work)

- OTLP/HTTP JSON wire shape — unchanged.
- Existing effet-otel functional tests — must pass on the rebuild.
- W3C trace context propagation — preserve.
- ADR 0006 recursion-avoidance pattern — caller-owned `~enabled:false` flag
  (eta-http already exposes the seam).
- LogLevel from the merge (Eta-mw8) — replaces ad-hoc severity strings.

### 2.2 Research probes (`scratch/eta_otel_v2/`)

- **R-T0 transparent cost** (Eta-331). The hard one. If user doesn't wire
  otel into Runtime, otel must be ~free at runtime: zero alloc, zero branch
  cost, zero binary bloat from unreachable otel code. Candidates documented
  in `scratch/eta_otel_rebuild/transparent_cost_research_plan.md` (per
  Eta-331). Verdict drives the dispatch mechanism. **Disproof signature**:
  no candidate achieves all three (alloc / branch / bloat) without breaking
  the Tracer API.
- **R-T1 peer analysis** (Eta-xgg). zio-telemetry, opentelemetry-effect (TS),
  opentelemetry-rust, tokio-tracing — patterns to adopt vs reject. Bounded
  desk research.
- **R-T2 OTLP capability inventory** (Eta-jxz). MUST/SHOULD/MAY mapped to
  Eta primitives. Bounded mapping work.
- **R-T3 (new) — exporter-on-eta-http**. Prove the rebuild's OTLP transport
  works end-to-end against a real OTel collector. Fixture: docker-compose
  collector + send 1000 spans + verify ingest. **Disproof**: ADR 0006's
  `~enabled:false` doesn't prevent recursion under production-shape use.

### 2.3 Slice plan

- **OS0 — Skeleton**: replace effet-otel with eta-otel scaffolding under
  `packages/eta-otel/`. Audit catalogs from line one. Existing effet-otel
  tests pinned as the regression gate.
- **OS1 — Type vocabulary**: Span, Metric, Log, Resource, InstrumentationScope
  as Eta-shaped types. Reuse Eta.Tracer / Capabilities seam (do not redefine
  spans).
- **OS2 — Pipelines**: span / metric / log signals → `Stream<event>` → batch
  via Eta primitives (Channel for backpressure, Effect.acquire_release for
  batch lifecycle).
- **OS3 — OTLP/HTTP exporter**: POST batches via eta-http; retry per ADR
  0005; `~enabled:false` on the eta-http call from inside the exporter to
  break recursion. R-T3 is the proof.
- **OS4 — Transparent cost**: implement R-T0's verdict.
- **OS5 — Self-instrumentation**: eta-otel exports its own batch metrics
  (queue depth, export rate, drop count) without recursion. Verified by R-T3.
- **OS6 — Tutorial + bench + cutover**: `docs/tutorial-eta-otel.md` walks a
  reader through the implementation as a worked example. Bench at-or-better
  than current effet-otel. Replace effet-otel imports across the tree.

### 2.4 Acceptance per slice

Same shape as eta-http v1: smoke target, audit updated,
`eta-oxcaml-test-shipped` passes, ADR amended where policy settles, journal
`V-Otel-{slice}` appended.

Plus track-specific: every slice runs effet-otel's existing functional tests
on the rebuild.

### 2.5 Stop conditions

- R-T0 verdict requires a primitive that doesn't exist (file as Eta extension;
  do not bury inside otel).
- ADR 0006's `~enabled:false` doesn't break recursion under R-T3 fixture;
  revisit the design.
- Bench regression vs current effet-otel; do not ship.
- Existing effet-otel functional tests fail on the rebuild; fix or report.

### 2.6 Current status

Track O OS0..OS6 has landed in `packages/eta-otel/`. Evidence is recorded in
`scratch/eta_otel_v2/`, package ADRs under `packages/eta-otel/docs/adrs/`,
and journal entries `V-Otel-OS3` through `V-Otel-OS6`. The latest live
Motel recheck is recorded in `V-Otel-MOTEL-RECHECK` and
`scratch/eta_otel_v2/os6_cutover/results/2026-05-24-motel-recheck.md`. Track
A Phase A-R, AC0..AC7, and AP1..AP4 have also landed and are accepted under
the available-account live-provider scope. Successful OpenAI paid, Together,
Fireworks, Kimi Code, Z.ai, and Moonshot canaries remain reopeners because the
current environment lacks the required accounts, product scope, or billing
state.

Track A A1 has landed as scratch evidence in
`scratch/eta_ai_v1/probes/provider_diff/`. Its verdict selects provider values
with small encode/decode functions over per-provider modules for the initial
eta-ai shape. A2..A5 are recorded below, and Phase A-R is closed by
`.objectives/eta-ai-shape-decision.md`.

Track A A2 has landed as scratch evidence in
`scratch/eta_ai_v1/probes/streaming_sse/`. Its verdict finds eta-http
`Body.Stream` sufficient for SSE parsing and release/discard, but files a
required eta-stream extension in
`packages/eta-stream/docs/adrs/0001-effect-reader-stream.md` before public
eta-ai streaming should expose `Eta_stream.Stream`.

Track A A3 has landed as scratch evidence in
`scratch/eta_ai_v1/probes/schema/`. Its verdict falsifies eta-schema
integration for v1 provider schemas because eta-schema has runtime codecs but
no JSON Schema exporter or provider-required vocabulary. The eta-schema gap is
filed in `packages/eta-schema/docs/adrs/0001-json-schema-export.md`; eta-ai
v1 should keep raw JSON tool schemas unless that extension lands first.

Track A A4 has landed as scratch evidence in
`scratch/eta_ai_v1/probes/tokenizer/`. Its verdict defers tokenizer support
from eta-ai v1, rejects byte-count token estimates for preflight budgeting,
and selects provider-side usage fields only.

Track A A5 has landed as scratch evidence in
`scratch/eta_ai_v1/probes/telemetry/`. Its verdict accepts OTel GenAI
semantic-convention attribute names for eta-ai spans, with stringified values
matching current Eta.Tracer/eta-http precedent.

`.objectives/eta-ai-shape-decision.md` has landed and closes Phase A-R.
Phase A-C has landed as AC0..AC7, constrained by the documented decisions:
provider values, raw JSON tool schemas in v1, provider-side usage only, OTel
GenAI span names, and no public Eta_stream-backed streaming API until the
eta-stream source primitive lands.

Track A AC0 and AC1 have landed in `packages/eta-ai/`. The package now has
the core public vocabulary, generated `eta-ai.opam`, audit catalogs, and
focused Alcotest coverage for messages, raw tool schemas, and provider errors.
AC2 provider abstraction is recorded separately below.

Track A AC2 has landed in `packages/eta-ai/`. The package now exposes the
provider value shape from A1: endpoint data, redacted-key auth header builder,
capability flags, chat encode/decode functions, SSE event decoder, and provider
error decoder. Public `Eta_stream.Stream` streaming remained outside AC2 and
is still blocked on the eta-stream source primitive decision.

Track A AC3 has landed as an eta-http-backed SSE pull parser in
`packages/eta-ai/`. It handles fragmented chunks, named events, tool-call
deltas, error events, done markers, bounded unframed buffers, and early body
discard. It deliberately does not expose `Eta_stream.Stream`; the eta-stream
source primitive remains the required next step before that public shape ships.

Track A AC4 has landed as a raw-JSON toolkit registry in `packages/eta-ai/`.
It preserves caller-supplied JSON Schema text, supports pipe-friendly
registration, rejects empty names/schemas and duplicate tool names, and keeps
eta-schema integration deferred until the JSON Schema exporter exists.

Track A AC5 has landed as GenAI telemetry wrappers in `packages/eta-ai/`.
Chat, streaming chat, embeddings, and tool execution effects now get
Eta.Tracer spans with the A5 attribute set, stringified values, `error.type`
on typed failures, no sensitive content attributes by default, and provider
transport observability suppression as the default helper.

Track A AC6 has landed in `packages/eta-ai/`. API keys now have an eta-ai
constructor returning `string Eta_redacted.t`, render as `<redacted:api_key>`,
are absent from eta-ai spans/logs under the telemetry wrappers, and have a
compile-fail fixture proving `Eta_ai.api_key` cannot be printed as a string.

Track A AC7 has landed as `docs/tutorial-eta-ai.md` plus
`packages/eta-ai/README.md`. The tutorial walks the core public surface using
a fake provider: provider values, redacted keys, raw JSON tools, chat effects,
SSE pull streaming, tool execution spans, telemetry, transport suppression, and
the package gates. Real provider package evidence is recorded in AP1 through
AP4 below.

Track A AP1 has landed in
`packages/eta-ai-openai/`. The package exports OpenAI Chat Completions and
Responses provider values, raw JSON structured-output support, function-tool
encoding/decoding, streaming chunk decoding, eta-http request runners, provider
error decoding, audit catalogs, README guidance, and fixture tests. The OpenAI
canary reached the provider through eta-http and returned a typed provider
error for the configured environment. A successful paid OpenAI canary is a
reopener rather than a completion blocker because the available OpenAI account
has no credit.

Track A AP2 has landed to the offline fixture/replay stage in
`packages/eta-ai-anthropic/`. The package exports Anthropic Messages API
provider values, top-level system encoding, tool_use/tool_result support, named
SSE event decoding, prompt-cache beta/header controls, eta-http request runners,
provider error decoding, audit catalogs, README guidance, and fixture tests.
The Anthropic canary reach probe passed with claude-haiku-4-5-20251001 after
the live model list showed the older Haiku model names were unavailable to this
key.

Track A AP3 has landed in
`packages/eta-ai-openai-compat/`. The package exports configurable
OpenAI-compatible provider values for base URL, chat path, bearer or raw-header
auth, extra headers, local OpenAI-style codecs, and eta-http runners.
Fixture tests cover Together-style and Mistral-style compatible envelopes,
streaming, provider errors, and transport suppression. Mistral, Groq, DeepSeek,
Novita, and Perplexity canaries passed. Kimi Code, Z.ai, Moonshot, Together,
and Fireworks remain account/product/billing reopeners rather than completion
blockers.

Track A AP4 has landed to the offline fixture/replay stage in
`packages/eta-ai-openrouter/`. The package exports OpenRouter provider values,
attribution headers, routing/fallback controls, local OpenAI-style codecs,
OpenRouter top-level and mid-stream provider error decoding, eta-http request
runners, audit catalogs, README guidance, and fixture tests. The OpenRouter
canary reach probe passed with openai/gpt-4o-mini.

Live provider dogfooding exposed an eta-http TLS setup gap before provider
payloads reached the wire: ocaml-tls needs Mirage_crypto_rng initialized.
`packages/eta-http/transport/connect.ml` now seeds the process-wide Mirage
crypto RNG before TLS handshakes so Eta_http.Client callers do not need
provider-specific RNG setup. The reusable release canary lives under
`scratch/eta_ai_v1/probes/live_reach/` with README, run script, verdict, and
sanitized result summary. The latest audit and shipped-gate recheck is recorded
in `V-AI-GATE-RECHECK` and
`scratch/eta_ai_v1/probes/live_reach/results/2026-05-24-audit-shipped-recheck.md`.

---

## 3. Track A — eta-ai

Research-driven. Implementation does not start until the API shape is settled
by evidence.

### 3.1 Phase A-R — research

The research question is which Effect AI patterns are domain essence and
which are TypeScript-specific ceremony. Probes test substance, not size.

Five probes, run in parallel where possible. All scratch labs under
`scratch/eta_ai_v1/`.

#### A1 — Provider diff probe

`scratch/eta_ai_v1/probes/provider_diff/`

Compute the actual diff between OpenAI, Anthropic, OpenAI-compat, OpenRouter
for chat completions + streaming + tool calling:
- Base URL, path
- Auth (header name, token format)
- Request body shape (system messages placement, user/assistant messages,
  tool definitions, params)
- Response body shape (choices, content blocks, tool calls)
- Streaming event shape (SSE event names, delta shape, terminal markers)
- Error JSON shape

Output: `provider_matrix.md` — rows are concerns, columns are providers.
Cells classify the difference: identical / parametrized-by-data /
structurally-different / not-applicable.

**Hypothesis under test**: most provider differences are parametrized-by-data
(URLs, header names, field names, event names). Structural differences are
the minority.

**Disproof signature**: any cell is "structurally-different" in a way that
cannot be expressed by a tagged variant or a small per-provider function
pointer. If the matrix says "structurally-different" for streaming framing
across all four providers, the providers-as-data shape is wrong; per-provider
modules are required.

The verdict shapes Phase A-C: do providers compose by data, or by code?

#### A2 — Streaming SSE probe

`scratch/eta_ai_v1/probes/streaming_sse/`

Provider responses arrive as SSE / `text/event-stream` over HTTP. eta-http v1
gives us `Response.body : Stream<bytes>`. Probe whether SSE → `Stream<event>`
parsing works with bounded memory and clean cancellation.

Test harness: replay recorded streams from OpenAI + Anthropic + OpenRouter
(small fixtures, no live keys). For each:
- Parse with bounded memory (RSS sample, not just `Gc.live_words`).
- Mid-stream cancellation releases the underlying h1 checkout / h2 stream
  permit (per eta-http S3's idempotent release).
- Tool-call delta accumulation works across chunk boundaries.
- Error events surface as typed errors, not parse errors.

**Disproof signature**: SSE framing requires a new Eta primitive (file as
eta-stream extension; do not bury in eta-ai); or chunk handling cannot
maintain back-pressure on consumer-cancellation.

#### A3 — Schema integration probe

`scratch/eta_ai_v1/probes/schema/`

Tool argument schemas + structured output schemas are JSON-Schema shapes.
Probe whether eta-schema expresses provider-required keywords (`oneOf`,
`anyOf`, `allOf`, `$ref`, `additionalProperties`, `enum`, nested objects,
recursive schemas).

Sample tool schemas from OpenAI's tool-calling docs and Anthropic's tool-use
docs. Round-trip through eta-schema. Sample structured output (OpenAI's
`response_format: json_schema`, Anthropic's structured output via tool use).

**Disproof signature**: eta-schema cannot represent provider-required
keywords. If yes, file an eta-schema gap as its own task; do **not** work
around inside eta-ai.

**Alternative if A3 falsifies**: v1 ships eta-ai with raw JSON tool schemas
(string-typed); structured output uses caller-provided JSON parsers. Defer
eta-schema integration to v1.x.

#### A4 — Tokenizer triage

`scratch/eta_ai_v1/probes/tokenizer/`

Do we ship a tokenizer? Options:
1. FFI to tiktoken-rs (Rust binding via ctypes). High value (accurate),
   high cost (FFI maintenance, build complexity).
2. Pure OCaml tokenizer (port BPE algorithm + vocab files). Highest accuracy
   cost but maximum control.
3. Defer to v1.x; approximate via byte counts + provider-side `usage` field.
4. Provider-side only — caller queries the provider for token counts where
   possible.

**Disproof signature for option 3**: cost estimation (the main use case) is
observably wrong without a real tokenizer for common cases (chat prefill
cost, prompt budgeting).

The verdict either keeps tokenizer in v1 scope or defers it; document the
trade-off.

#### A5 — Telemetry seam probe

`scratch/eta_ai_v1/probes/telemetry/`

eta-ai must emit spans for chat / completion / embedding using `Eta.Tracer`;
if eta-otel is loaded, the spans flow through. ADR 0006's `~enabled:false`
carries forward for AI calls that themselves should not be re-traced.

Probe: produce sample spans for one chat call + one streaming call + one
tool-calling call. Compare attribute names against the OTel `gen_ai.*`
semantic conventions.

**Disproof signature**: span attributes for AI don't have a clean OTel
semconv mapping. If yes, document our chosen attribute set as ADR with
explicit version pinning.

### 3.2 Phase A-R deliverable

`.objectives/eta-ai-shape-decision.md` records the verdicts:
- A1 → providers-as-data vs per-provider-modules (with the matrix as
  evidence)
- A2 → SSE shape settled (or eta-stream extension filed)
- A3 → eta-schema integration in v1 (or deferred)
- A4 → tokenizer in v1 or deferred
- A5 → telemetry attribute set named

**Implementation does not start until this document lands.** No code in
`packages/eta-ai/` before Phase A-R closes with explicit verdicts and
disconfirming-evidence trails.

### 3.3 Phase A-C — eta-ai core

Once Phase A-R closes, implement what the research justifies. The slice list
below names the obligations; the actual shape and ordering follow the A-R
verdicts.

- **AC0 — Skeleton**: `packages/eta-ai/` with audit catalogs.
- **AC1 — Type vocabulary**: `Ai_error`, `Prompt`, `Message` (system / user /
  assistant / tool), `Response`, `Model`, `Tool`, `Tool_call`. Use OCaml
  variants where TypeScript would use discriminated unions.
- **AC2 — Provider abstraction** (shape from A1):
  - If providers-as-data wins: `type provider = { ... }`. Each provider is a
    value, not a module.
  - If per-provider modules win: small functor or first-class module
    interface. Each provider is its own .ml.
- **AC3 — Streaming Response**: `Stream<event>` consuming SSE chunks from
  eta-http (per A2 verdict). Handles partial messages, tool-call deltas,
  error events.
- **AC4 — Tool / Toolkit**: composable, `|>`-friendly tool registration.
  Schema-validated args (per A3 verdict).
- **AC5 — Telemetry**: span emission via `Eta.Tracer` (per A5 verdict).
- **AC6 — Redacted API keys**: API keys travel as `Redacted.t` from the merge
  (Eta-jo5). Logs and traces never expose them. Compile-fail attempts to
  print are part of the test surface.
- **AC7 — Public surface + tutorial**: `docs/tutorial-eta-ai.md` walks
  readers through one end-to-end chat completion + streaming + tool call.

### 3.4 Phase A-P — provider sub-packages

Four packages, each independently shippable. Shape determined by A1.

- **AP1 — eta-ai-openai**: chat completions, responses API, function calling,
  structured output (per A3 verdict), streaming. **First** because it sets
  the pattern other providers follow.
- **AP2 — eta-ai-anthropic**: messages API, tool use, streaming, prompt
  caching headers.
- **AP3 — eta-ai-openai-compat**: local OpenAI-compatible provider profile with
  configurable base URL + auth. Targets: Together, Mistral, Groq, Fireworks,
  DeepSeek, etc.
- **AP4 — eta-ai-openrouter**: routing across providers, fallback chains,
  attribution headers, and provider-specific error shapes.

**Per-provider acceptance**:
- Smoke target: real API call against a recorded fixture (no live keys
  committed; record once + replay for offline CI).
- One reach probe per provider against a canary endpoint (live, runs
  per-release not per-commit; needs API key in CI secrets).
- Audit catalog updated.
- README documents the provider-specific config surface and any quirks.
- Tutorial extended with one end-to-end example per provider.

### 3.5 Stop conditions for Track A

- A1 forces an API shape that breaks `|>` pipelines or requires Lwt-style
  monadic chaining in caller code. Stop and report.
- A3 reveals an eta-schema gap that needs core eta-schema work. File the
  gap; do not work around in eta-ai.
- A2 forces a new Stream primitive. File as eta-stream extension with its
  own ADR + journal entry; do not bury in eta-ai.
- Phase A-R closes with no clear verdict on shape (multiple candidates
  equally supported by evidence). Stop; preference must not decide in absence
  of evidence.
- A provider package surfaces a structural difference that wasn't in A1's
  matrix (i.e., the matrix was incomplete). Update the matrix; revisit Phase
  A-C if the abstraction shape was wrong.
- Correctness regression vs the recorded fixtures. Do not ship.

### 3.6 What we are not optimizing for

This track does not have a code-size target, a line-count budget, or a
density metric. The Effect AI reference is not the size we copy; it is also
not the size we beat. The research question is which patterns are domain
essence vs TypeScript ceremony, and the implementation that follows is
whatever shape the evidence justifies. The audit catalogs and the priority
order (correctness > DX > performance) are the discipline.

---

## 4. Sequencing

```
[Eta-1yb merge: Redacted, LogLevel, MutableRef, Semaphore]
         |
         v
+--------+---------+
|                  |
v                  v
Track O         Track A Phase A-R (research, no code)
(eta-otel rebuild)        |
S0 → S6                   v
                          A-R verdicts settled
                          |
                          v
                          Track A Phase A-C (eta-ai core)
                          AC0 → AC7
                          |
                          v
                          Track A Phase A-P (providers)
                          AP1 (OpenAI) → AP2,3,4 in parallel
```

**Hard ordering**:
- The merge (Eta-1yb) must land before Track O or Track A start. Both consume
  Redacted, LogLevel, etc.
- Track A Phase A-C does not start until A-R closes with explicit verdicts.
- Track A Phase A-P does not start until eta-ai core ships AC1+AC2+AC3.

**Parallelism**:
- Track O slices and Track A research can run simultaneously after the
  merge.
- Track A providers AP2 / AP3 / AP4 can run in parallel after AP1 lands.

**Why this ordering**: eta-otel is bounded and produces the in-tree real
consumer of eta-http v1 immediately. eta-ai is research-heavy and shouldn't
block on eta-otel's bench-against-effet-otel work. They share eta-http but
otherwise don't block each other.

---

## 5. Per-track ship gates

For every slice in either track:

1. Smoke target passes.
2. Audit catalogs (`audit/dep_usage.md`, `audit/eta_escapes.md`) updated.
3. `nix develop -c eta-oxcaml-test-shipped` passes.
4. ADRs amended where policy settles.
5. Backlog task closed by planner with summary in `close_reason`.
6. Journal entry `V-{Track}-{Slice}` appended at the bottom of `journal.md`.

Track-specific:
- **Track O**: every slice runs effet-otel's existing functional tests.
- **Track A Phase A-R**: every probe records its disproof-signature outcome
  in `scratch/eta_ai_v1/probes/<probe>/verdict.md`.
- **Track A Phase A-P**: every provider passes a recorded-fixture smoke +
  one live reach probe per release.

---

## 6. Out of scope (explicitly)

For Track O:
- HTTP/3 / QUIC OTLP transport.
- Non-OTLP/HTTP transports (gRPC OTLP, Jaeger native, Zipkin v2).
- OpenTelemetry SDK extensions beyond what effet-otel already covers.

For Track A:
- McpSchema / McpServer (Model Context Protocol). Defer to v1.x.
- AnthropicStructuredOutput / OpenAiStructuredOutput as core modules. Push
  into provider packages.
- Tokenizer (per A4 probe verdict — likely v1.x).
- Code-generation from OpenAPI specs for provider clients. Hand-write v1;
  revisit if maintenance pain materializes.
- HTTP/3 / QUIC for AI providers. eta-http v1 doesn't ship h3.
- Model fine-tuning, training, batch APIs. v1 is inference + (optional)
  embeddings only.
- Image generation (DALL-E, Stable Diffusion APIs).
- Audio (Whisper transcription, TTS). Defer.
- Vision input (multimodal messages). v1.x; flagged in AC1 type vocabulary
  as a placeholder variant.

---

## 7. What the experimenter should not do

- Copy code from Effect AI, openai-node, anthropic-sdk-typescript, or any
  reference library.
- Skip Phase A-R and start implementing eta-ai before the API shape is
  settled by evidence.
- Add deps beyond §1.3 without stopping and asking.
- Bury Eta-extension primitives inside eta-ai or eta-otel. If a slice
  surfaces a primitive gap (e.g., new Stream operator, new Capability), ship
  it in the proper Eta package with its own ADR + journal entry.
- Promote a candidate API shape from Phase A-R based on TypeScript
  familiarity ("this is how Effect does it"). The shape must win on
  observable criteria.
- Treat synthetic fixtures as proof of provider behavior. Recorded fixtures
  for offline CI are fine; live reach probes per release are required.
- Mix Track O and Track A slice work in single commits. Keep history
  bisectable.
- Optimize for any unstated metric (line count, file count, module count,
  benchmark micro-result). The stated priorities are correctness > DX >
  performance, in that order.

---

## 8. Backlog state

**Existing tasks** that fold in:

- Eta-5zo (eta-otel rebuild epic) — Track O umbrella.
- Eta-yo4 (Phase R) + Eta-331 (R-T0) + Eta-xgg (R-T1) + Eta-jxz (R-T2) —
  Track O Phase R sub-tasks.
- Eta-jo5 (Redacted), Eta-mw8 (LogLevel), Eta-lho (MutableRef), Eta-1gj
  (Semaphore) — close as Eta-1yb merge lands.

**To file** (planner action after this objective lands and merge closes):

- Track O slice tasks: OS0, OS1, OS2, OS3, OS4, OS5, OS6 under Eta-5zo.
- Track A research probe tasks: A1 (provider diff), A2 (streaming), A3
  (schema), A4 (tokenizer), A5 (telemetry) under a new Eta-AI-Research task.
- Track A core epic with slice tasks AC0..AC7.
- Provider epics: AP1 (OpenAI), AP2 (Anthropic), AP3 (OpenAI-compat), AP4
  (OpenRouter).
- Add R-T3 (exporter-on-eta-http) under Eta-yo4.

---

## 9. Open questions for planner before starting

- Track A Phase A-P naming: flat top-level packages (`eta-ai-openai`,
  `eta-ai-anthropic`, etc.) or sub-tree under `packages/eta-ai/providers/`?
  **Recommendation**: separate top-level packages, each with its own opam
  file, for independent versioning.
- Live reach probe budget: how often does eta-ai-{provider} run live API
  calls? **Recommendation**: per release, single canary call per provider,
  fixture recording for offline CI.
- `eta-ai-shape-decision.md` location: `.objectives/` or `scratch/eta_ai_v1/`?
  **Recommendation**: `.objectives/` since it's a sub-objective that
  constrains Phase A-C, not a research lab artifact.
- Provider package versioning: lockstep with eta-ai core, or independent?
  **Recommendation**: lockstep for v1; revisit at v2 when API stabilizes.

---

This document is the master objective. Update it as tracks land. When in
doubt, this file wins.
