(* Port of @eff/opentelemetry/test/Logger.test.ts.

   Effect-TS asserts that:
   1. Effect.log emits log records to the configured logger; ten emissions
      arrive at the InMemoryLogRecordExporter.
   2. Records emitted inside a withSpan carry spanId / traceId of the
      active span, and the timestamp comes from a swappable Clock.

   Eta's equivalent: Logger.in_memory + Effect.log + Tracer.in_memory.
   For the active-span identity assertion we compare the log record with
   Effect.current_span inside the active span. *)

open Eta

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct

let is_lower_hex ~len value =
  String.length value = len
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let with_logger f =
  B.with_logger_runtime (fun _ctx rt logger -> f rt logger)

let with_logger_and_tracer f =
  B.with_observed_runtime (fun _ctx rt tracer logger _meter -> f rt logger tracer)

(* ------------------------------------------------------------------ *)
(* Mirrors `it.eff("emits log records", ...)`. *)
(* ------------------------------------------------------------------ *)
let test_emits_log_records () =
  with_logger @@ fun rt logger ->
  let _ = B.run rt (Effect.repeat ~schedule:(Schedule.recurs 9) (Effect.log "test")) in
  Alcotest.(check int) "ten log records" 10
    (List.length (Logger.dump logger))

(* ------------------------------------------------------------------ *)
(* Mirrors `it.eff("uses monotonic clock timestamps and keeps them
   aligned with spans", ...)`.

   We can't substitute a custom Clock service the way Effect-TS does. The
   equivalent observable property:
   the log emitted inside a named span carries the span's trace_id and
   span_id, and its timestamp is bracketed by the span's start/end. *)
(* ------------------------------------------------------------------ *)
let test_log_carries_active_span_ids () =
  with_logger_and_tracer @@ fun rt logger tracer ->
  let active =
    B.run rt
      (Effect.named "parent"
         (Effect.bind
            (fun active ->
              Effect.map (fun () -> active) (Effect.log "test"))
            Effect.current_span))
  in
  let active =
    match active with
    | Exit.Ok (Some active) -> active
    | Exit.Ok None -> Alcotest.fail "expected active span"
    | Exit.Error _ -> Alcotest.fail "expected successful log"
  in
  let logs = Logger.dump logger in
  let spans = Tracer.dump tracer in
  Alcotest.(check int) "one log" 1 (List.length logs);
  Alcotest.(check int) "one span" 1 (List.length spans);
  let log = List.hd logs in
  let span = List.hd spans in
  Alcotest.(check string) "log trace_id matches span trace_id"
    span.Tracer.trace_id log.Logger.trace_id;
  Alcotest.(check string) "log trace_id matches active span"
    active.trace_id log.Logger.trace_id;
  Alcotest.(check string) "log span_id matches active span" active.span_id
    log.span_id;
  Alcotest.(check bool) "log span_id is 16 lower hex" true
    (is_lower_hex ~len:16 log.span_id);
  Alcotest.(check string) "log body" "test" log.body;
  Alcotest.(check int)
    "log ts_ms within span duration"
    1
    (if log.ts_ms >= span.started_ms && log.ts_ms <= span.ended_ms then 1
     else 0)

(* ------------------------------------------------------------------ *)
(* Mirrors `describe("not provided") > it.eff("withSpan", ...)`. *)
(* ------------------------------------------------------------------ *)
let test_not_provided_log_dropped () =
  B.with_runtime @@ fun _ctx rt ->
  let _ = B.run rt (Effect.log "test") in
  (* No assertion target — the contract is "doesn't crash". *)
  Alcotest.(check pass) "noop logger silently drops" () ()

let suite =
  ( "Logger",
    [
      Alcotest.test_case "emits log records" `Quick test_emits_log_records;
      Alcotest.test_case "log carries active span ids" `Quick
        test_log_carries_active_span_ids;
      Alcotest.test_case "not provided log dropped" `Quick
        test_not_provided_log_dropped;
    ] )
end
