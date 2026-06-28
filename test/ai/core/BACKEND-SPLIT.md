# Backend Split

Most `eta_ai` core scenarios now live in `test/ai_common` and are instantiated
by `test/ai_eio`. Those tests cover vocabulary, provider records/codecs,
toolkit validation, SSE stream parsing/closing, and telemetry through Eta
runtime adapters.

`test/ai/core` remains Eio-specific because its remaining test builds an
`Eio_mock.Net` H1 transport and an `Eta_http_eio.Client.make_h1 ~sw ~net` client to
verify that oversized HTTP error bodies are capped before provider decoding.
That behavior depends on raw Eio networking fixtures rather than only the Eta
runtime contract.

The `negative/` compile tests also remain here. They are compiler/package
boundary checks for secret redaction and do not exercise either runtime
backend.
