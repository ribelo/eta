(* Port intent of @effect/opentelemetry/test/Metrics.test.ts.

   Effect-TS ships `effect/Metric` (gauges, counters, histograms,
   incremental + cumulative, double + bigint), and `@effect/opentelemetry`
   converts a registry of metrics into an OTel `ResourceMetrics` payload at
   collection time.

   Effet has no metrics module. The Effect-TS test exercises:

   - `Metric.gauge("rps")` updated with attributes; verifies the OTel
     `OBSERVABLE_GAUGE` data points are merged by attribute set.
   - `Metric.gauge` with `bigint: true` → `INT` value type, same merge.
   - `Metric.counter("counter")` → cumulative `UP_DOWN_COUNTER` (non-monotonic).
   - `Metric.counter("counter-inc", { incremental: true })` → monotonic
     `COUNTER`.
   - bigint variant of the incremental counter.

   Two design observations:

   - **Leveraging OCaml.** OCaml has no `effect/Metric` analogue in stdlib,
     but the ecosystem uses `prometheus`, `mtime`, or the `metrics`
     package; an Effet-friendly metrics module would be a thin ZIO-style
     layer that exposes counters/gauges/histograms via `Capabilities.meter`
     and an `Effet_otel.meter` adapter that emits OTLP/JSON `/v1/metrics`.

   - **Out of scope for the tracer.** Metrics are independent of the
     tracer trait. They deserve their own epic and their own opam package
     surface so applications that only want tracing don't pay for them.

   This file documents the gap. The Effect-TS shape it would mirror is
   sketched in the comment below. *)

(* TODO(effet-otel): implement once Capabilities.meter and an OTLP/JSON
   metrics exporter ship.

   Reference test (Effect-TS):

     it.effect("gauge", () => Effect.gen(function*() {
       const gauge = Metric.gauge("rps")
       yield* Metric.update(gauge, 10)
       const results = yield* Effect.promise(() => producer.collect())
       assert.deepStrictEqual(findMetric(results, "rps"), { ... })
     }))
*)

let placeholder () = Alcotest.skip ()

let suite =
  ( "Metrics",
    [ Alcotest.test_case "Metric.gauge → OTLP metrics (deferred)" `Quick
        placeholder ] )
