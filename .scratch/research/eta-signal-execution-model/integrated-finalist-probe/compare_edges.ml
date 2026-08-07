(* Complete selected-factory Eta/Eio edge tapes.  Reference values remain in
   the tracked probe result/summary CSV files; this executable emits candidates. *)

module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module Signal = Selected_factory_fresh.Make (Observer_error) ()

type error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error ]

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}

exception Probe_failure

let failf format = Printf.ksprintf failwith format

let cause_message cause =
  Eta.Cause.pretty (fun _ -> "typed failure") cause

let widen (effect : ('a, [< error ]) E.t) : ('a, error) E.t =
  E.map_error (fun error -> (error :> error)) effect

let run_ok runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> failwith (cause_message cause)

let run_failed runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok () -> failwith "expected operation failure"

let run_defect runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      failf "expected defect, got %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "expected defect"

let rec effect_loop step remaining =
  if remaining = 0 then E.unit
  else E.bind (fun () -> effect_loop step (remaining - 1)) step

let observe runtime signal callback =
  run_ok runtime
    (Signal.Observer.observe signal ~on_update:callback)

let make_failed_retry runtime depth =
  let source = Signal.Var.create 0 in
  let fail_next = ref false in
  let rec chain index signal =
    if index > depth then signal
    else
      let map =
        if index = depth then
          Signal.map (fun value ->
              if !fail_next then raise Probe_failure;
              value + 1)
        else Signal.map (( + ) 1)
      in
      chain (index + 1) (map signal)
  in
  let output = chain 1 (Signal.Var.watch source) in
  let observer =
    run_ok runtime (Signal.Observer.observe output)
  in
  run_ok runtime Signal.stabilize;
  let next = ref 0 in
  let step =
    E.bind
      (fun value ->
        E.bind
          (fun () ->
            E.bind
              (function
                | Eta.Exit.Error (Eta.Cause.Die _) ->
                    E.bind
                      (fun () -> Signal.stabilize)
                      (E.sync (fun () -> fail_next := false))
                | Eta.Exit.Ok () ->
                    E.sync (fun () ->
                        failwith "failing stabilization succeeded")
                | Eta.Exit.Error cause ->
                    E.sync (fun () ->
                        failwith (cause_message cause)))
              (E.to_exit (widen Signal.stabilize)))
          (Signal.Var.set source value))
      (E.sync (fun () ->
           fail_next := true;
           incr next;
           !next))
  in
  {
    name = Printf.sprintf "failed_retry.depth_%d.position_last" depth;
    run_batch =
      (fun operations ->
        run_ok runtime (effect_loop step operations));
    check =
      (fun () ->
        let observed = run_ok runtime (Signal.Observer.read observer) in
        if observed <> !next + depth then
          failf "failed retry depth %d: expected %d, observed %d"
            depth (!next + depth) observed);
  }

let make_dynamic_cleanup runtime =
  let source = Signal.Var.create false in
  let selected =
    Signal.bind (Signal.Var.watch source) ~f:(fun active ->
        Signal.const (if active then 1 else 0))
  in
  let observer = observe runtime selected (fun _ -> E.unit) in
  run_ok runtime Signal.stabilize;
  let next = ref 0 in
  let step =
    E.bind
      (fun value ->
        E.bind (fun () -> Signal.stabilize)
          (Signal.Var.set source value))
      (E.sync (fun () ->
           next := 1 - !next;
           !next <> 0))
  in
  {
    name = "dynamic_scope_cleanup";
    run_batch =
      (fun operations ->
        run_ok runtime (effect_loop step operations));
    check =
      (fun () ->
        let observed = run_ok runtime (Signal.Observer.read observer) in
        if observed <> !next then
          failf "dynamic cleanup: expected %d, observed %d" !next observed);
  }

let await_cancelled label promise =
  match Eio.Promise.await_exn promise with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Error cause ->
      failf "%s returned Eta error: %s" label (cause_message cause)
  | Eta.Exit.Ok () -> failf "%s returned success" label

let await_ok label promise =
  match Eio.Promise.await_exn promise with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      failf "%s returned Eta error: %s" label (cause_message cause)

let make_cancelled_contender runtime sw =
  let source = Signal.Var.create 0 in
  let blocker = ref None in
  let output =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           (match !blocker with
           | None -> ()
           | Some (started_resolver, release) ->
               Eio.Promise.resolve started_resolver ();
               Eio.Promise.await release;
               blocker := None);
           value + 1)
  in
  let observer =
    run_ok runtime (Signal.Observer.observe output)
  in
  run_ok runtime Signal.stabilize;
  let completed = ref 0 in
  let run_one () =
    let value = !completed + 1 in
    run_ok runtime (Signal.Var.set source value);
    let started, started_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    blocker := Some (started_resolver, release);
    let holder =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Eta.Runtime.run runtime (widen Signal.stabilize))
    in
    Eio.Promise.await started;
    let context = ref None in
    let contender =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Eio.Cancel.sub @@ fun cancel_context ->
          context := Some cancel_context;
          Eta.Runtime.run runtime
            (widen (Signal.Var.set source (value + 1))))
    in
    for _ = 1 to 5 do
      Eio.Fiber.yield ()
    done;
    Option.iter
      (fun cancel_context -> Eio.Cancel.cancel cancel_context Exit)
      !context;
    Eio.Promise.resolve release_resolver ();
    await_cancelled "candidate queued contender" contender;
    await_ok "candidate lane holder" holder;
    incr completed
  in
  {
    name = "cancelled_contender";
    run_batch =
      (fun operations ->
        for _ = 1 to operations do
          run_one ()
        done);
    check =
      (fun () ->
        let observed = run_ok runtime (Signal.Observer.read observer) in
        if observed <> !completed + 1 then
          failwith "cancelled contender committed the wrong value");
  }

let make_observer_failure_retry runtime =
  let source = Signal.Var.create 0 in
  let fail_next = ref false in
  let observer =
    observe runtime (Signal.Var.watch source) (fun _ ->
        if !fail_next then (
          fail_next := false;
          E.fail `Observer_failed)
        else E.unit)
  in
  run_ok runtime Signal.stabilize;
  let completed = ref 0 in
  {
    name = "observer_failure_retry";
    run_batch =
      (fun operations ->
        for _ = 1 to operations do
          incr completed;
          fail_next := true;
          run_ok runtime (Signal.Var.set source !completed);
          run_failed runtime Signal.stabilize;
          run_ok runtime Signal.stabilize
        done);
    check =
      (fun () ->
        let observed = run_ok runtime (Signal.Observer.read observer) in
        if observed <> !completed then
          failwith "observer retry state mismatch");
  }

let make_observer_disposal runtime =
  let source = Signal.Var.create 0 in
  let before = (run_ok runtime (Signal.stats ())).active_observer_count in
  {
    name = "observer_disposal";
    run_batch =
      (fun operations ->
        for _ = 1 to operations do
          let observer =
            run_ok runtime
              (Signal.Observer.observe (Signal.Var.watch source))
          in
          run_ok runtime (Signal.Observer.dispose observer)
        done);
    check =
      (fun () ->
        let after = (run_ok runtime (Signal.stats ())).active_observer_count in
        if after <> before then failwith "observer disposal leaked demand");
  }

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

  let compare_sleeper left right =
    match Int.compare left.deadline_ms right.deadline_ms with
    | 0 -> Int.compare left.sequence right.sequence
    | order -> order

  let rec insert sleeper = function
    | [] -> [ sleeper ]
    | next :: rest as sleepers ->
        if compare_sleeper sleeper next <= 0 then sleeper :: sleepers
        else next :: insert sleeper rest

  let sleep t duration =
    let deadline_ms = t.now_ms + Eta.Duration.to_ms duration in
    let promise, resolver = Eio.Promise.create () in
    let sequence = t.next_sequence in
    t.next_sequence <- sequence + 1;
    t.sleepers <- insert { deadline_ms; sequence; resolver } t.sleepers;
    try Eio.Promise.await promise
    with exn ->
      t.sleepers <-
        List.filter
          (fun sleeper -> sleeper.sequence <> sequence)
          t.sleepers;
      raise exn

  let rec adjust_to t target =
    match t.sleepers with
    | sleeper :: rest when sleeper.deadline_ms <= target ->
        t.sleepers <- rest;
        t.now_ms <- sleeper.deadline_ms;
        Eio.Promise.resolve sleeper.resolver ();
        Eio.Fiber.yield ();
        adjust_to t target
    | [] | _ :: _ -> t.now_ms <- target

  let adjust t duration =
    adjust_to t (t.now_ms + Eta.Duration.to_ms duration)

  let sleeper_count t = List.length t.sleepers
end

let rec wait_until label predicate attempts =
  if predicate () then ()
  else if attempts = 0 then failf "timed out: %s" label
  else (
    Eio.Fiber.yield ();
    wait_until label predicate (attempts - 1))

let make_timer_cycle runtime clock =
  let timer =
    run_ok runtime (Signal.Time.interval (Eta.Duration.ms 1))
  in
  let completed = ref 0 in
  {
    name = "timer_cycle";
    run_batch =
      (fun operations ->
        for _ = 1 to operations do
          let observer = observe runtime timer (fun _ -> E.unit) in
          wait_until "candidate timer start"
            (fun () -> Test_clock.sleeper_count clock = 1)
            100;
          Test_clock.adjust clock (Eta.Duration.ms 1);
          wait_until "candidate timer wake"
            (fun () -> Test_clock.sleeper_count clock = 1)
            100;
          run_ok runtime Signal.stabilize;
          run_ok runtime (Signal.Observer.dispose observer);
          wait_until "candidate timer stop"
            (fun () -> Test_clock.sleeper_count clock = 0)
            100;
          incr completed
        done);
    check =
      (fun () ->
        if Test_clock.sleeper_count clock <> 0 then
          failwith "timer cycle leaked sleeper";
        ignore !completed);
  }

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run_batch operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure ~samples ~smoke workload =
  let operations = if smoke then 1 else calibrate workload 1 in
  if not smoke then (
    workload.run_batch operations;
    workload.check ();
    Gc.full_major ());
  Printf.printf
    "side,name,pair,operations,sample,wall_ns,allocated_words\n%!";
  let pair = Option.value (Sys.getenv_opt "PAIR") ~default:"1" in
  for sample = 1 to samples do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run_batch operations;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major = Gc.counters () in
    workload.check ();
    let count = float_of_int operations in
    let wall_ns = ((stopped -. started) *. 1e9) /. count in
    let allocated_words =
      ((after_minor -. before_minor)
       +. (after_major -. before_major)
       -. (after_promoted -. before_promoted))
      /. count
    in
    Printf.printf "candidate,%s,%s,%d,%d,%.6f,%.6f\n%!"
      workload.name pair operations sample wall_ns allocated_words
  done

let parse_args () =
  let rec loop only samples smoke = function
    | [] -> only, samples, smoke
    | "--only" :: name :: rest -> loop (Some name) samples smoke rest
    | "--samples" :: count :: rest ->
        loop only (int_of_string count) smoke rest
    | "--smoke" :: rest -> loop only 1 true rest
    | argument :: _ -> invalid_arg ("unknown argument: " ^ argument)
  in
  loop None 9 false (List.tl (Array.to_list Sys.argv))

let () =
  let only, samples, smoke = parse_args () in
  let selected =
    match only with
    | Some selected -> selected
    | None -> invalid_arg "exactly one workload is required: --only NAME"
  in
  if samples <= 0 then invalid_arg "--samples must be positive";
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock environment)
      ~sleep:(Test_clock.sleep clock)
      ~now_ms:(fun () -> clock.Test_clock.now_ms)
      ()
  in
  let candidates =
    [
      "failed_retry.depth_1.position_last",
        (fun () -> make_failed_retry runtime 1);
      "failed_retry.depth_10.position_last",
        (fun () -> make_failed_retry runtime 10);
      "failed_retry.depth_100.position_last",
        (fun () -> make_failed_retry runtime 100);
      "dynamic_scope_cleanup",
        (fun () -> make_dynamic_cleanup runtime);
      "cancelled_contender",
        (fun () -> make_cancelled_contender runtime sw);
      "observer_failure_retry",
        (fun () -> make_observer_failure_retry runtime);
      "observer_disposal",
        (fun () -> make_observer_disposal runtime);
      "timer_cycle",
        (fun () -> make_timer_cycle runtime clock);
    ]
  in
  match List.assoc_opt selected candidates with
  | None -> invalid_arg ("unknown workload: " ^ selected)
  | Some make ->
      let workload = make () in
      measure ~samples ~smoke workload
