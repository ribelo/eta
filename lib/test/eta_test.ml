module Test_clock = struct
  type sleeper = {
    deadline_ms : int;
    sequence : int;
    resolver : unit Eio.Promise.u;
  }

  type t = {
    mutable now_ms : int;
    mutable next_sequence : int;
    mutable sleepers : sleeper list;
  }

  let create () = { now_ms = 0; next_sequence = 0; sleepers = [] }

  let sleeper_compare a b =
    match Int.compare a.deadline_ms b.deadline_ms with
    | 0 -> Int.compare a.sequence b.sequence
    | order -> order

  let rec insert_sleeper sleeper = function
    | [] -> [ sleeper ]
    | next :: rest as sleepers ->
        if sleeper_compare sleeper next <= 0 then sleeper :: sleepers
        else next :: insert_sleeper sleeper rest

  let take_next_due t target_ms =
    match t.sleepers with
    | [] -> None
    | sleeper :: rest when sleeper.deadline_ms <= target_ms ->
        t.sleepers <- rest;
        Some sleeper
    | _ -> None

  let rec wake_until t target_ms =
    match take_next_due t target_ms with
    | None -> t.now_ms <- target_ms
    | Some sleeper ->
        t.now_ms <- sleeper.deadline_ms;
        Eio.Promise.resolve sleeper.resolver ();
        Eio.Fiber.yield ();
        wake_until t target_ms

  let sleep t duration =
    let deadline_ms = t.now_ms + Eta.Duration.to_ms duration in
    if deadline_ms <= t.now_ms then ()
    else
      let promise, resolver = Eio.Promise.create () in
      let sequence = t.next_sequence in
      t.next_sequence <- t.next_sequence + 1;
      t.sleepers <-
        insert_sleeper { deadline_ms; sequence; resolver } t.sleepers;
      Eio.Promise.await promise

  let adjust t duration =
    wake_until t (t.now_ms + Eta.Duration.to_ms duration)

  let set_time t time_ms =
    wake_until t (max 0 time_ms)

  let sleeper_count t = List.length t.sleepers
end

let with_logger f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let logger = Eta.Logger.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~logger:(Eta.Logger.as_capability logger) ()
  in
  f sw rt logger

let with_tracer f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw rt tracer

let with_logger_and_tracer f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let logger = Eta.Logger.in_memory () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~logger:(Eta.Logger.as_capability logger)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw rt logger tracer

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ()
  in
  f sw clock rt

let with_traced_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw clock rt tracer

module Async = struct
  type 'a promise = 'a Eio.Promise.t

  let fork_run sw rt eff =
    let promise, resolver = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolver (Eta.Runtime.run rt eff));
    promise

  let await = Eio.Promise.await

  let unresolved () =
    let promise, _resolver = Eio.Promise.create () in
    promise

  let yield = Eio.Fiber.yield
end

module Expect = struct
  let pp_hidden_error fmt _ = Format.pp_print_string fmt "<err>"

  let expect_ok = function
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Ok, got Error %a"
          (Eta.Cause.pp pp_hidden_error) cause

  let expect_typed_failure exit predicate =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Fail err) when predicate err -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected matching typed failure, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected matching typed failure, got Ok"

  let expect_typed_failure_eq test exit expected =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Fail actual) ->
        Alcotest.check test "typed failure" expected actual
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected typed failure, got Ok"

  let expect_die exit predicate =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Die die) when predicate die -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected matching Die, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected matching Die, got Ok"

  let expect_interrupt = function
    | Eta.Exit.Error (Eta.Cause.Interrupt _) -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected Interrupt, got Ok"
end

module Test_random = struct
  let create ~seed = Eta.Capabilities.random_of_seed seed
  let set_seed = Eta.Capabilities.random_set_seed
end
