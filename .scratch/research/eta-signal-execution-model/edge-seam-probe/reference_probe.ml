(* PROTOTYPE: This executable measures the pinned pre-replacement Signal edge
   operations through the current public API. It is not production code. *)

module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module S = Eta_signal.Make (Observer_error) ()

let failf format = Printf.ksprintf failwith format

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
        List.filter (fun sleeper -> sleeper.sequence <> sequence) t.sleepers;
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

  let now_ms t = t.now_ms
  let sleeper_count t = List.length t.sleepers
end

type probe_error =
  [ S.graph_error
  | S.observer_read_error
  | S.stabilize_error
  | S.time_error ]

let cause_message cause =
  Eta.Cause.pretty (fun _ -> "typed failure") cause

let widen (effect : ('a, [< probe_error ]) E.t) : ('a, probe_error) E.t =
  E.map_error (fun error -> (error :> probe_error)) effect

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime (widen effect) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> failwith (cause_message cause)

let run_error runtime effect =
  match Eta_eio.Runtime.run runtime (widen effect) with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok () -> failwith "expected reference operation to fail"

let rec wait_until label predicate attempts =
  if predicate () then ()
  else if attempts = 0 then failf "timed out: %s" label
  else (
    Eio.Fiber.yield ();
    wait_until label predicate (attempts - 1))

type workload = {
  name : string;
  run : int -> unit;
  check : unit -> unit;
}

let observer_failure_retry runtime =
  let source = S.Var.create 0 in
  let fail_next = ref false in
  let observer =
    run_ok runtime
      (S.Observer.observe (S.Var.watch source) ~on_update:(fun _ ->
           if !fail_next then (
             fail_next := false;
             E.fail `Observer_failed)
           else E.unit))
  in
  run_ok runtime S.stabilize;
  let completed = ref 0 in
  {
    name = "observer_failure_retry";
    run =
      (fun operations ->
        for _ = 1 to operations do
          incr completed;
          fail_next := true;
          run_ok runtime (S.Var.set source !completed);
          run_error runtime S.stabilize;
          run_ok runtime S.stabilize
        done);
    check =
      (fun () ->
        let observed = run_ok runtime (S.Observer.read observer) in
        if observed <> !completed then
          failwith "reference observer retry state mismatch");
  }

let observer_disposal runtime =
  let source = S.Var.create 0 in
  {
    name = "observer_disposal";
    run =
      (fun operations ->
        for _ = 1 to operations do
          let observer =
            run_ok runtime (S.Observer.observe (S.Var.watch source))
          in
          run_ok runtime (S.Observer.dispose observer)
        done);
    check = (fun () -> ());
  }

let timer_cycle runtime clock =
  let timer = run_ok runtime (S.Time.interval (Eta.Duration.ms 1)) in
  {
    name = "timer_cycle";
    run =
      (fun operations ->
        for _ = 1 to operations do
          let observer =
            run_ok runtime
              (S.Observer.observe timer ~on_update:(fun _ -> E.unit))
          in
          wait_until "reference timer start"
            (fun () -> Test_clock.sleeper_count clock = 1)
            100;
          Test_clock.adjust clock (Eta.Duration.ms 1);
          wait_until "reference timer wake"
            (fun () -> Test_clock.sleeper_count clock = 1)
            100;
          run_ok runtime S.stabilize;
          run_ok runtime (S.Observer.dispose observer);
          wait_until "reference timer stop"
            (fun () -> Test_clock.sleeper_count clock = 0)
            100
        done);
    check = (fun () -> ());
  }

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure workload samples =
  let operations = calibrate workload 1 in
  workload.run operations;
  workload.check ();
  Gc.full_major ();
  Printf.printf "side,name,pair,operations,sample,wall_ns,allocated_words\n%!";
  let pair = Option.value (Sys.getenv_opt "PAIR") ~default:"1" in
  for sample = 1 to samples do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run operations;
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
    Printf.printf "reference,%s,%s,%d,%d,%.6f,%.6f\n%!" workload.name pair
      operations sample wall_ns allocated_words
  done

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--measure"; name; "--samples"; samples ] ->
      Eio_main.run @@ fun environment ->
      Eio.Switch.run @@ fun sw ->
      let clock = Test_clock.create () in
      let runtime =
        Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock environment)
          ~sleep:(Test_clock.sleep clock)
          ~now_ms:(fun () -> Test_clock.now_ms clock)
          ()
      in
      let workload =
        match name with
        | "observer_failure_retry" -> observer_failure_retry runtime
        | "observer_disposal" -> observer_disposal runtime
        | "timer_cycle" -> timer_cycle runtime clock
        | _ -> invalid_arg ("unknown reference workload: " ^ name)
      in
      measure workload (int_of_string samples)
  | _ ->
      invalid_arg "use --measure WORKLOAD --samples COUNT"
