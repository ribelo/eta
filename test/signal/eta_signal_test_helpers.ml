let () =
  match Sys.getenv_opt "EIO_BACKEND" with
  | None | Some "" ->
      (Unix.putenv [@alert "-unsafe_multidomain"]) "EIO_BACKEND" "posix"
  | Some _ -> ()

open Eta

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

(* Most tests shadow [Signal] with a fresh functor instance so graph indexes do
   not accumulate across cases. This top-level instance provides the shared
   error row used by helpers below. *)
module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ `Update_failed
  | Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Eta_signal_stream.stream_error ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<signal-error>"

let widen (eff : ('a, [< test_error ]) Effect.t) : ('a, test_error) Effect.t =
  Effect.map_error (fun err -> (err :> test_error)) eff

let run_ok rt eff =
  match Eta_eio.Runtime.run rt (widen eff) with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let expect_fail :
    type a. string -> (test_error -> bool) -> (a, test_error) Exit.t -> unit =
 fun label pred -> function
  | Exit.Error (Cause.Fail err) when pred err -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected typed failure, got Ok" label

let expect_die label = function
  | Exit.Error (Cause.Die _) -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected defect, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected defect, got Ok" label

let expect_exact_runtime_mismatch label = function
  | Exit.Error (Cause.Fail `Runtime_mismatch) -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected only Runtime_mismatch, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected Runtime_mismatch, got Ok" label

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec matches_at haystack_index needle_index =
    needle_index = needle_len
    || (haystack_index + needle_index < haystack_len
       && Char.equal haystack.[haystack_index + needle_index]
            needle.[needle_index]
       && matches_at haystack_index (needle_index + 1))
  in
  let rec search index =
    needle_len = 0
    || (index + needle_len <= haystack_len
       && (matches_at index 0 || search (index + 1)))
  in
  search 0

let rec finalizer_has_die_message expected = function
  | Cause.Finalizer.Die die ->
      contains_substring (Printexc.to_string die.exn) expected
  | Cause.Finalizer.Fail _ | Cause.Finalizer.Interrupt _ -> false
  | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
      List.exists (finalizer_has_die_message expected) causes
  | Cause.Finalizer.Finalizer cause -> finalizer_has_die_message expected cause
  | Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_die_message expected primary
      || finalizer_has_die_message expected finalizer

let rec cause_has_finalizer_die_message expected = function
  | Cause.Finalizer finalizer -> finalizer_has_die_message expected finalizer
  | Cause.Suppressed { primary; finalizer } ->
      cause_has_finalizer_die_message expected primary
      || finalizer_has_die_message expected finalizer
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_finalizer_die_message expected) causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false

let expect_finalizer_die label expected = function
  | Exit.Error cause when cause_has_finalizer_die_message expected cause -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected finalizer defect %S, got %a" label expected
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.failf "%s: expected finalizer defect, got Ok" label

let domain_spawn f =
  (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"]) f

let run_in_domain f =
  let domain = domain_spawn f in
  Domain.join domain

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f rt

let wait_for_sleepers clock expected =
  let rec loop attempts =
    if Eta_test.Test_clock.sleeper_count clock >= expected then ()
    else if attempts = 0 then
      Alcotest.failf "expected %d sleepers, got %d" expected
        (Eta_test.Test_clock.sleeper_count clock)
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 20

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let await_cancelled label promise =
  try
    match Eio.Promise.await_exn promise with
    | Exit.Ok _ -> Alcotest.failf "%s: expected Eio cancellation, got Ok" label
    | Exit.Error cause ->
        Alcotest.failf "%s: expected Eio cancellation, got %a" label
          (Cause.pp pp_hidden) cause
  with Eio.Cancel.Cancelled _ -> ()

let expect_exit_ok label = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Ok, got %a" label (Cause.pp pp_hidden) cause

let with_runtime_and_switch f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f sw rt

let with_yield_after_daemon_fork_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let daemon_forked, daemon_forked_resolver = Eio.Promise.create () in
  let daemon_forked_once = ref false in
  let module Eio_ops = struct
    module Time = Eio.Time
    module Net = Eio.Net
    module Flow = Eio.Flow
    module Switch = Eio.Switch

    module Fiber = struct
      let get = Eio.Fiber.get
      let with_binding = Eio.Fiber.with_binding
      let first = Eio.Fiber.first
      let await_cancel = Eio.Fiber.await_cancel
      let fork = Eio.Fiber.fork

      let fork_daemon ~sw f =
        Eio.Fiber.fork_daemon ~sw f;
        if not !daemon_forked_once then (
          daemon_forked_once := true;
          Eio.Promise.resolve daemon_forked_resolver ();
          Eio.Fiber.yield ())

      let yield = Eio.Fiber.yield
      let check = Eio.Fiber.check
    end

    module Stream = Eio.Stream
    module Cancel = Eio.Cancel
  end in
  let host =
    Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()
  in
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock env) @@ fun rt ->
  f sw rt daemon_forked

let with_logger_test_clock f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let logger = Eta_observability.Logger.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~logger:(Eta_observability.Logger.as_capability logger) ()
  in
  f sw clock rt logger
