module Execution = struct
  type t = { mutable held : bool; mutable entries : int }

  let create () = { held = false; entries = 0 }

  let run t operation =
    if t.held then operation (fun () -> ())
    else (
      t.held <- true;
      t.entries <- t.entries + 1;
      Fun.protect
        ~finally:(fun () -> t.held <- false)
        (fun () -> operation (fun () -> ())))
end

module E = Selected_edges.Make (Execution)

exception Injected of string
exception Interrupted

let failf format = Printf.ksprintf failwith format
let check label condition = if not condition then failwith label

let success = E.Success ()
let typed label = E.Failure (E.Typed_failure label)
let defect label = E.Failure (E.Defect (Injected label))
let interrupted = E.Failure (E.Interrupted Interrupted)

let expect_callback label = function
  | Error (E.Callback_failure (E.Typed_failure actual))
    when String.equal label actual ->
      ()
  | _ -> failf "expected callback failure %s" label

let observer_checks () =
  let execution = Execution.create () in
  let edges = E.create execution in
  let trace = ref [] in
  let dependency =
    E.observe edges (fun _ ->
        check "dependency callback held lane" (not execution.held);
        trace := "dependency" :: !trace;
        success)
  in
  let consumer =
    E.observe edges (fun _ ->
        check "consumer callback held lane" (not execution.held);
        trace := "consumer" :: !trace;
        success)
  in
  E.publish edges dependency 1;
  E.publish edges consumer 1;
  check "observer plan failed"
    (E.run edges ~runtime:1
       ~plan:[ E.Observer dependency; E.Observer consumer ]
     = Ok ());
  check "observer plan was not dependency-first"
    (List.rev !trace = [ "dependency"; "consumer" ]);
  let mode = ref `Typed in
  let tokens = ref [] in
  let retry =
    E.observe edges (fun delivery ->
        check "sealed current absent"
          (Option.is_some (E.current delivery));
        tokens := delivery :: !tokens;
        match !mode with
        | `Typed -> typed "typed"
        | `Defect -> defect "defect"
        | `Interrupted -> interrupted
        | `Success -> success)
  in
  E.publish edges retry 7;
  expect_callback "typed"
    (E.run edges ~runtime:1 ~plan:[ E.Observer retry ]);
  mode := `Defect;
  (match E.run edges ~runtime:1 ~plan:[ E.Observer retry ] with
  | Error (E.Callback_failure (E.Defect (Injected "defect"))) -> ()
  | _ -> failwith "defect classification or retry token failed");
  mode := `Interrupted;
  (match E.run edges ~runtime:1 ~plan:[ E.Observer retry ] with
  | Error (E.Callback_failure (E.Interrupted Interrupted)) -> ()
  | _ -> failwith "interruption classification or retry token failed");
  check "failed deliveries changed sealed token"
    (match !tokens with
    | third :: second :: first :: _ ->
        E.current first = E.current second && E.current second = E.current third
    | _ -> false);
  let first_delivery = List.hd (List.rev !tokens) in
  check "old sealed capability did not retain exact pending token"
    (E.acknowledge first_delivery);
  check "acknowledged failed delivery retried"
    (E.run edges ~runtime:1 ~plan:[ E.Observer retry ] = Ok ()
     && List.length !tokens = 3);
  check "sealed delivery remained current after settlement"
    (List.for_all (fun delivery -> E.current delivery = None) !tokens);
  let retry_attempts = ref 0 in
  let retry_success =
    E.observe edges (fun delivery ->
        incr retry_attempts;
        match E.current delivery with
        | Some (E.Initialized 12) when !retry_attempts = 2 -> success
        | Some (E.Initialized _) when !retry_attempts = 1 -> typed "retry"
        | _ -> failwith "retry did not coalesce latest initialization")
  in
  E.publish edges retry_success 11;
  expect_callback "retry"
    (E.run edges ~runtime:1 ~plan:[ E.Observer retry_success ]);
  E.publish edges retry_success 12;
  check "observer retry did not succeed"
    (E.run edges ~runtime:1 ~plan:[ E.Observer retry_success ] = Ok ()
     && !retry_attempts = 2);
  let acknowledged =
    E.observe edges (fun delivery ->
        check "first acknowledge rejected" (E.acknowledge delivery);
        check "second acknowledge accepted" (not (E.acknowledge delivery));
        typed "after_ack")
  in
  E.publish edges acknowledged 9;
  expect_callback "after_ack"
    (E.run edges ~runtime:1 ~plan:[ E.Observer acknowledged ]);
  check "acknowledged callback retried"
    (E.run edges ~runtime:1 ~plan:[ E.Observer acknowledged ] = Ok ());
  let published = ref 0 in
  let stream =
    E.observe edges (fun delivery ->
        E.publish_sealed delivery (fun _ ->
            check "stream publication held lane" (not execution.held);
            incr published;
            interrupted))
  in
  E.publish edges stream 10;
  (match E.run edges ~runtime:1 ~plan:[ E.Observer stream ] with
  | Error (E.Callback_failure (E.Interrupted Interrupted)) -> ()
  | _ -> failwith "stream interruption did not escape");
  check "stream publication was retried after acknowledgement"
    (E.run edges ~runtime:1 ~plan:[ E.Observer stream ] = Ok ()
     && !published = 1);
  let finishes = ref [] in
  let disposing = ref None in
  let raced =
    E.observe edges
      ~finish:(fun reason ->
        check "finish hook held lane" (not execution.held);
        finishes := reason :: !finishes;
        success)
      (fun _ ->
        E.dispose edges (Option.get !disposing);
        success)
  in
  disposing := Some raced;
  E.publish edges raced 1;
  check "callback disposal failed"
    (E.run edges ~runtime:1 ~plan:[ E.Observer raced ] = Ok ());
  check "finish hook ran in callback phase" (!finishes = []);
  check "finish hook failed"
    (E.run edges ~runtime:1 ~plan:[] = Ok ());
  E.dispose edges raced;
  E.invalidate edges raced;
  ignore (E.run edges ~runtime:1 ~plan:[]);
  check "finish did not run exactly once" (!finishes = [ E.Disposed ]);
  let invalid_finishes = ref 0 in
  let invalid =
    E.observe edges
      ~finish:(fun reason ->
        check "wrong invalid reason" (reason = E.Invalid_scope);
        incr invalid_finishes;
        success)
      (fun _ -> failwith "invalid observer callback ran")
  in
  E.publish edges invalid 2;
  E.invalidate edges invalid;
  check "invalid cleanup failed"
    (E.run edges ~runtime:1 ~plan:[ E.Observer invalid ] = Ok ());
  check "invalid finish count" (!invalid_finishes = 1);
  Printf.printf "observers: pass\n%!"

let policy execution starts stops fail_start fail_stop =
  E.
    {
      same_runtime = Int.equal;
      start =
        (fun _runtime ~generation:_ ->
          check "timer start held lane" (not execution.Execution.held);
          incr starts;
          if !fail_start then (
            fail_start := false;
            defect "start")
          else
            Success
              (fun () ->
                check "timer stop held lane" (not execution.Execution.held);
                if !fail_stop then (
                  fail_stop := false;
                  defect "stop")
                else (
                  incr stops;
                  success)));
    }

let timer_checks () =
  let execution = Execution.create () in
  let edges = E.create execution in
  let starts = ref 0 and stops = ref 0 in
  let fail_start = ref true and fail_stop = ref false in
  let timer =
    E.create_timer edges ~runtime:7
      ~policy:(policy execution starts stops fail_start fail_stop)
  in
  E.set_timer_demand edges timer true;
  (match E.run edges ~runtime:7 ~plan:[] with
  | Error (E.Cleanup_failures [ E.Defect (Injected "start") ]) -> ()
  | _ -> failwith "failed start was not reported");
  check "failed start lost retry" (E.queued_timer_count edges = 1);
  check "start retry failed" (E.run edges ~runtime:7 ~plan:[] = Ok ());
  let first = E.timer_generation timer in
  check "live wake rejected"
    (E.timer_wake edges ~runtime:7 timer ~generation:first = Ok true);
  E.set_timer_demand edges timer false;
  check "generation was not fenced before stop"
    (E.timer_generation timer > first);
  check "late wake accepted"
    (E.timer_wake edges ~runtime:7 timer ~generation:first = Ok false);
  fail_stop := true;
  (match E.run edges ~runtime:7 ~plan:[] with
  | Error (E.Cleanup_failures [ E.Defect (Injected "stop") ]) -> ()
  | _ -> failwith "failed stop was not reported");
  check "failed stop lost retry" (E.queued_timer_count edges = 1);
  check "stop retry failed" (E.run edges ~runtime:7 ~plan:[] = Ok ());
  E.set_timer_demand edges timer true;
  ignore (E.run edges ~runtime:7 ~plan:[]);
  let daemon_generation = E.timer_generation timer in
  E.daemon_failed edges timer ~generation:daemon_generation;
  check "daemon failure lost retry" (E.queued_timer_count edges = 1);
  check "daemon restart failed" (E.run edges ~runtime:7 ~plan:[] = Ok ());
  let foreign =
    E.create_timer edges ~runtime:8
      ~policy:(policy execution (ref 0) (ref 0) (ref false) (ref false))
  in
  E.set_timer_demand edges foreign true;
  check "runtime mismatch was not typed"
    (E.run edges ~runtime:7 ~plan:[] = Error E.Runtime_mismatch);
  check "runtime mismatch claimed queued timers"
    (E.queued_timer_count edges = 1);
  check "foreign runtime retry failed"
    (E.run edges ~runtime:8 ~plan:[] = Ok ());
  check "foreign wake accepted"
    (E.timer_wake edges ~runtime:7 foreign
       ~generation:(E.timer_generation foreign)
     = Error E.Runtime_mismatch);
  Printf.printf "timers: pass\n%!"

let cleanup_and_affected_checks () =
  let execution = Execution.create () in
  let edges = E.create execution in
  let observer_calls = ref 0 in
  let observer =
    E.observe edges (fun _ ->
        incr observer_calls;
        success)
  in
  E.publish edges observer 1;
  let finish_order = ref [] in
  let make_finished n =
    let observer =
      E.observe edges
        ~finish:(fun _ ->
          finish_order := n :: !finish_order;
          if n < 3 then defect (string_of_int n) else success)
        (fun _ -> success)
    in
    E.dispose edges observer
  in
  make_finished 1;
  make_finished 2;
  make_finished 3;
  (match E.run edges ~runtime:1 ~plan:[ E.Observer observer ] with
  | Error
      (E.Cleanup_failures
        [ E.Defect (Injected "1"); E.Defect (Injected "2") ]) ->
      ()
  | _ -> failwith "cleanup failures were not aggregated in order");
  check "cleanup did not attempt every hook"
    (List.rev !finish_order = [ 1; 2; 3 ]);
  check "cleanup failure delivered observer" (!observer_calls = 0);
  check "observer did not remain pending"
    (E.run edges ~runtime:1 ~plan:[ E.Observer observer ] = Ok ()
     && !observer_calls = 1);
  List.iter
    (fun affected ->
      let execution = Execution.create () in
      let edges = E.create execution in
      let starts = ref 0 in
      let p = policy execution starts (ref 0) (ref false) (ref false) in
      let _ballast =
        List.init 100_000 (fun _ ->
            E.create_timer edges ~runtime:1 ~policy:p)
      in
      let timers =
        List.init affected (fun _ ->
            E.create_timer edges ~runtime:1 ~policy:p)
      in
      List.iter (fun timer -> E.set_timer_demand edges timer true) timers;
      check "affected run failed" (E.run edges ~runtime:1 ~plan:[] = Ok ());
      check "timer claim count scanned ballast"
        ((E.stats edges).timer_claims = affected && !starts = affected))
    [ 1; 32; 1_024 ];
  Printf.printf "cleanup/affected: pass\n%!"

let () =
  observer_checks ();
  timer_checks ();
  cleanup_and_affected_checks ();
  Printf.printf "selected_edges checks passed\n%!"
