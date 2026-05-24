open Eta
open Eta_test

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_ok test name expected = function
  | Exit.Ok actual -> Alcotest.check test name expected actual
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_error test name expected = function
  | Exit.Ok _ -> Alcotest.fail "expected Error"
  | Exit.Error cause -> Alcotest.check test name expected cause

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  f rt tracer

let with_sampled_traced_runtime sampler f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~sampler ()
  in
  f rt tracer

let with_auto_traced_runtime auto_instrument f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~auto_instrument ()
  in
  f rt tracer

let with_runtime_capture_backtrace capture_backtrace f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~capture_backtrace ()
  in
  f rt

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver (Runtime.run rt eff));
  promise

let dur_ms = Duration.ms
let some_dur = Alcotest.option (Alcotest.testable Duration.pp Duration.equal)
let dur = Alcotest.testable Duration.pp Duration.equal
let string_cause =
  Alcotest.testable (Cause.pp Format.pp_print_string) (Cause.equal String.equal)
let rec string_cause_contains expected = function
  | Cause.Fail actual -> String.equal expected actual
  | Cause.Die _ | Cause.Interrupt _ -> false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (string_cause_contains expected) causes
  | Cause.Suppressed { primary; finalizer } ->
      string_cause_contains expected primary
      || string_cause_contains expected finalizer

let check_string_cause_contains label expected cause =
  Alcotest.(check bool) label true (string_cause_contains expected cause)

let rec string_cause_has_suppressed_finalizer expected = function
  | Cause.Suppressed { primary = Cause.Interrupt _; finalizer } ->
      string_cause_contains expected finalizer
  | Cause.Suppressed { primary; finalizer } ->
      string_cause_has_suppressed_finalizer expected primary
      || string_cause_has_suppressed_finalizer expected finalizer
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (string_cause_has_suppressed_finalizer expected) causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false

let check_suppressed_finalizer label expected cause =
  Alcotest.(check bool)
    label true (string_cause_has_suppressed_finalizer expected cause)

let check_concurrent_cause label cause =
  match cause with
  | Cause.Concurrent (_ :: _) -> ()
  | _ ->
      Alcotest.failf "%s: expected Concurrent cause, got %a" label
        (Cause.pp Format.pp_print_string) cause

let attr key span = List.assoc_opt key span.Tracer.attrs

let link_span_id span =
  List.map (fun link -> link.Tracer.link_span_id) span.Tracer.links

let only_span tracer =
  match Tracer.dump tracer with
  | [ span ] -> span
  | spans ->
      Alcotest.failf "expected one span, got %d" (List.length spans)

let check_status name expected actual =
  match (expected, actual) with
  | Tracer.Ok, Tracer.Ok -> ()
  | Tracer.Cancelled, Tracer.Cancelled -> ()
  | Tracer.Error _, Tracer.Error _ -> ()
  | _ -> Alcotest.failf "%s: unexpected span status" name

let is_lower_hex ~len value =
  String.length value = len
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let require_current_span = function
  | Some span -> span
  | None -> Alcotest.fail "expected current span"

let check_error_message name expected actual =
  match actual with
  | Tracer.Error msg -> Alcotest.(check string) name expected msg
  | _ -> Alcotest.failf "%s: expected Error status" name

type observability_err = [ `Boom | `Db of int | `Inner | `Outer ]

let wait_until ?(attempts = 200) pred =
  let rec loop n =
    if pred () then ()
    else if n = 0 then Alcotest.fail "condition did not become true"
    else (
      Eio_unix.sleep 0.001;
      loop (n - 1))
  in
  loop attempts

let contains_substring haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec at pos i =
    i = n_len
    || (pos + i < h_len
       && Char.equal haystack.[pos + i] needle.[i]
       && at pos (i + 1))
  in
  let rec search pos =
    if n_len = 0 then true
    else if pos + n_len > h_len then false
    else at pos 0 || search (pos + 1)
  in
  search 0

let rec cause_has_die_message expected = function
  | Cause.Die die -> contains_substring (Printexc.to_string die.exn) expected
  | Cause.Fail _ | Cause.Interrupt _ -> false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_die_message expected) causes
  | Cause.Suppressed { primary; finalizer } ->
      cause_has_die_message expected primary
      || cause_has_die_message expected finalizer

let check_die_message label expected cause =
  Alcotest.(check bool) label true (cause_has_die_message expected cause)

