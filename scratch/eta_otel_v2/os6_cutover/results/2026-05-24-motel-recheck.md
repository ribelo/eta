# 2026-05-24 Motel Recheck

Question: does the eta-otel test suite still export traces, logs, and metrics
through the local Motel OTLP/HTTP collector after the eta-http and eta-ai
dogfooding work?

Motel setup:

```text
motel status
exit 0
running: true
url: http://127.0.0.1:27686
databasePath: /home/ribelo/projects/ribelo/ocaml/Eta/.motel-data/telemetry.sqlite

motel endpoints
exit 0
exporterUrl: http://127.0.0.1:27686/v1/traces
logsExporterUrl: http://127.0.0.1:27686/v1/logs
```

Verification:

```text
nix develop -c dune runtest packages/eta-otel --force
exit 0
29 tests run
motel/live export: OK
Tracer/withSpanContext OTLP live: OK
Logger/log OTLP live: OK
Metrics/metrics OTLP live: OK
```

External collector query:

```text
motel services
exit 0
eta-otel-itest
eta-otel-test-logger
eta-otel-test-tracer

motel traces eta-otel-itest 5
exit 0
latest traces include demo.root with 5 spans and demo.failing with 1 error span

motel logs eta-otel-test-logger
exit 0
latest logs include INFO records with traceId/spanId for hello from inside parent
and still inside
```

Verdict: accepted. The local Motel daemon is reachable from this worktree and
the eta-otel suite still proves live OTLP/HTTP trace, log, and metric export.
This does not change the separate eta-ai provider-key caveats.
