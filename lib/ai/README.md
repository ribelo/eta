# eta_ai

`eta_ai` is the core AI vocabulary package for Eta.

## What it is

It owns provider-agnostic types and helpers that every Eta AI provider shares:

- messages, prompts, content blocks, tool calls, and responses;
- provider records, API-key redaction, and telemetry wrappers;
- an eta_http-backed SSE pull parser for streaming responses;
- raw JSON tool schemas and a small Yojson helper surface.

## Why it is separate

Provider packages (`eta_ai_openai`, `eta_ai_anthropic`, `eta_ai_openrouter`,
`eta_ai_openai_compat`) own provider-specific HTTP encoding and decoding.
`eta_ai` keeps the shared vocabulary in one small package so providers can
share types without each provider depending on every other provider.

## Package boundary

- `eta_ai` depends on `eta`, `eta_redacted`, `eta_http`, and `yojson`.
- It does not depend on any provider package.
- It does not depend on `eta_http_eio`; provider packages that want the default
  Eio transport add that themselves.
- It has no SDK or tokenizer dependency.

## How to use it

Pick a provider package and pass an `eta_ai` request value:

```ocaml
let request =
  {
    Eta_ai.model = "gpt-4o-mini";
    prompt = [ Eta_ai.User [ Eta_ai.Text "weather in Warsaw" ] ];
    tools = [];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    stream = false;
  }
```

Pass `request` to `Eta_ai_openai.responses`, `Eta_ai_anthropic.messages`, or
another provider runner. Provider packages are documented under
`lib/ai/<provider>/README.md`.

## Limits

- `eta_ai` does not make HTTP requests. It describes them.
- Raw tool and structured-output schemas are plain JSON strings until
  `eta_schema` exposes JSON Schema generation.
- Token counting is intentionally absent; use provider usage fields.
- Live provider reach is tested only with an API key, never in the default
  `dune runtest` gate.

## Tradeoffs

- Shared vocabulary means provider-specific quirks live in provider packages,
  not in `eta_ai`.
- Redacted API keys keep secrets out of logs and traces, but an application
  that extracts the raw key with `Eta_redacted.value` is responsible for where
  it sends that value.

## Development

Run the package tests:

```sh
nix develop -c dune runtest test/ai --force
```

Run the full gate:

```sh
nix develop -c dune runtest --force
```

Without Nix, after `opam install . --deps-only --with-test`, use `dune runtest test/ai --force`.
