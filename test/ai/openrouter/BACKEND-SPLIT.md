# Backend Split

The OpenRouter provider tests are backend-neutral Eta behavior. They cover
provider headers, routing and request encoding, fixture decoding, custom Eta
HTTP clients, stream errors, embeddings, task APIs, binary runners, and
telemetry span suppression without raw Eio networking or switch APIs.

The suite now lives in `openrouter_common_suites.ml` and is instantiated by
`run_eio.ml`. Fixture files remain local to this directory and
are declared as test dependencies for that runner.
