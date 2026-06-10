# Backend Split

The OpenAI provider tests are backend-neutral Eta behavior. They cover provider
configuration, chat/responses/embeddings/image/audio/transcription/realtime
request encoding, fixture decoding, custom Eta HTTP clients, stream handling,
provider errors, and telemetry span suppression without raw Eio networking or
switch APIs.

The suite now lives in `openai_common_suites.ml` and is instantiated by
`run_eio.ml`. Fixture files remain local to this directory and
are declared as test dependencies for that runner.
