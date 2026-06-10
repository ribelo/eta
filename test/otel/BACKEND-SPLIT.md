# Backend Split

In-memory OTEL behavior now lives in `test/otel_common` and is instantiated by
`test/otel_eio` and `test/otel_lwt`. That shared suite covers tracer span
context, logger records/span IDs, metric aggregation, and OTLP JSON encoding
that does not require a live Eio exporter.

`test/otel` remains Eio-specific for exporter integration. Its remaining tests
construct `Eta_otel.create ~sw ~net ~clock`, start local TCP response servers,
talk to optional motel on `127.0.0.1:27686`, and exercise exporter queue, retry,
backpressure, self-span, self-metric, and live OTLP behavior. Those scenarios
depend on raw Eio networking and switch lifetimes rather than only the Eta
runtime contract.
