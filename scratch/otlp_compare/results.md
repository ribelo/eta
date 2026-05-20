# V-O7r Lab Results

Command:

\`\`\`sh
nix develop -c dune exec scratch/otlp_compare/runtime_smoke.exe
\`\`\`

Output:

\`\`\`text
otlp_compare runtime smoke passed
\`\`\`

## What The Lab Models

Current \`effet-otel\`:

- fixed per-signal batching: traces 32, logs 64, metrics 128
- one HTTP attempt per batch
- failed batches surface only through \`on_error\`
- no retry, backoff, bounded queue metrics, or built-in dropped-signal accounting

\`ocaml-opentelemetry\`-style adapter:

- batching enabled by default
- bounded queue behavior
- retry with exponential backoff
- self diagnostics for retries and drops

The adapter model is not a linked implementation. It is a research fixture based on
the upstream 0.90/0.91 opam files and source survey.

## Decision-Relevant Results

| Fixture | Current hand-roll | Upstream-style adapter |
| --- | --- | --- |
| Collector OK | Delivers all items | Delivers all items |
| Collector down | Drops failed batches after one attempt; \`on_error\` only | Retries before dropping; emits retry/drop diagnostics |
| Intermittent first failure | Drops the first batch | Retries and delivers |
| Slow collector / queue pressure | Export loop can block; no bounded-drop telemetry | Bounded queue makes pressure observable |
| Propagation | Effet core owns W3C extract/inject after V-P | Upstream has W3C/span-context pieces, but not a drop-in Effet runtime context |

## Recommendation

Do not migrate to the upstream adapter yet. Keep the hand-rolled package for its
small dependency closure and direct Effet runtime integration, but retire the
old zero-dependency rationale and add upstream-inspired failure semantics only
after approval:

- retry with bounded exponential backoff;
- explicit dropped-signal accounting;
- richer \`on_error\` payloads;
- optional self-diagnostic hook or counters.
