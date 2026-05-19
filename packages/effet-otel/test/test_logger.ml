(* Port intent of @effect/opentelemetry/test/Logger.test.ts.

   Effect-TS ships an `Effect.log` primitive whose entries flow into OTel
   logs when a `NodeSdk.layer` configured with a `logRecordProcessor` is
   provided. The test asserts that:

   1. `Effect.log("test")` emits a log record into the OTel logs pipeline
      and counts arrive at the `InMemoryLogRecordExporter`.
   2. The log's `hrTime` and `hrTimeObserved` come from `Clock` (i.e. an
      Effect service, swappable in tests) and align with the start time of
      a containing `withSpan` span.
   3. The log carries `attributes.spanId` and `attributes.traceId` matching
      the active span's identity.

   Effet has no `Effect.log` and no logs subsystem. Two design observations:

   - **Leveraging OCaml.** OCaml applications already use the `Logs` library
     (or `Logs_lwt`, `logs.fmt`, etc.) for application logging. The natural
     bridge is a custom `Logs` reporter that reads the active span via
     `Effect.current_span` and forwards the record to `Effet_otel`. That
     reporter would need a small `Effet_otel.emit_log` entry point and an
     OTLP/JSON `/v1/logs` exporter; neither exists today.

   - **Trait scope.** Adding logs to `Capabilities.tracer` would conflate
     two OTel signals on one trait. A separate `Capabilities.logger` (with
     `noop` and `Logger.in_memory` implementations) is the cleaner shape.

   This file documents the gap. The Effect-TS shape it would mirror lives
   in the source comment below; it is *not* compiled into a passing test.
   See the matching backlog item for the implementation plan. *)

(* TODO(effet-otel): implement once Capabilities.logger ships.

   Reference test (Effect-TS):

     it.effect("emits log records", () =>
       Effect.gen(function*() {
         yield* Effect.log("test").pipe(Effect.repeat({ times: 9 }))
         assert.lengthOf(exporter.getFinishedLogRecords(), 10)
       }).pipe(Effect.provide(TracingLive)))

   Effet equivalent (target):

     let test_emits_log_records () =
       with_traced_runtime @@ fun rt logs_exporter ->
       let prog =
         Effect.repeat (Schedule.recurs 9)
           (Effet.Logger.info "test")
       in
       let _ = Runtime.run rt prog in
       Alcotest.(check int) "ten log records" 10
         (Logger.dump logs_exporter |> List.length)
*)

let placeholder () =
  (* A live Alcotest case so dune doesn't drop the module; documents the
     deferred work and links to the journal entry. *)
  Alcotest.skip ()

let suite =
  ( "Logger",
    [
      Alcotest.test_case "Effect.log → OTLP logs (deferred)" `Quick
        placeholder;
    ] )
