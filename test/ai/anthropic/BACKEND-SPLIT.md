# Backend Split

The Anthropic provider tests are backend-neutral Eta behavior. They exercise
provider configuration, request encoding, fixture decoding, custom Eta HTTP
clients, stream decoding, provider errors, prompt-cache headers, and telemetry
span suppression without raw Eio networking or switch APIs.

The suite now lives in `anthropic_common_suites.ml` and is instantiated by
`run_eio.ml`. Fixture files remain local to this directory and
are declared as test dependencies for that runner.
