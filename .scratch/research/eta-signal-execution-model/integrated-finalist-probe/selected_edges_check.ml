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

let rec bounded label remaining step finished =
  if finished () then ()
  else if remaining = 0 then failwith ("bounded completion: " ^ label)
  else (
    step ();
    bounded label (remaining - 1) step finished)

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
  let raised_publications = ref 0 in
  let raised_stream =
    E.observe edges (fun delivery ->
        E.publish_sealed delivery (fun _ ->
            incr raised_publications;
            raise Interrupted))
  in
  E.publish edges raised_stream 11;
  (match E.run edges ~runtime:1 ~plan:[ E.Observer raised_stream ] with
  | exception Interrupted -> ()
  | _ -> failwith "raised stream interruption did not escape");
  check "raised stream interruption split publication and acknowledgement"
    (E.run edges ~runtime:1 ~plan:[ E.Observer raised_stream ] = Ok ()
     && !raised_publications = 1);
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
  let raised_attempts = ref 0 in
  let raised_interrupt =
    E.observe edges (fun _ ->
        incr raised_attempts;
        if !raised_attempts = 1 then raise Interrupted else success)
  in
  E.publish edges raised_interrupt 3;
  (match E.run edges ~runtime:1 ~plan:[ E.Observer raised_interrupt ] with
  | exception Interrupted -> ()
  | _ -> failwith "raised interruption did not escape");
  check "raised interruption did not restore pending delivery"
    (E.run edges ~runtime:1 ~plan:[ E.Observer raised_interrupt ] = Ok ()
     && !raised_attempts = 2);
  let nested_calls = ref 0 in
  let nested =
    E.observe edges (fun _ ->
        incr nested_calls;
        success)
  in
  let outer =
    E.observe edges (fun _ ->
        E.publish edges nested 4;
        check "nested edge run failed"
          (E.run edges ~runtime:1 ~plan:[ E.Observer nested ] = Ok ());
        success)
  in
  E.publish edges outer 4;
  bounded "nested same-fiber edge call" 2
    (fun () ->
      ignore
        (E.run edges ~runtime:1 ~plan:[ E.Observer outer ]))
    (fun () -> !nested_calls = 1);
  let reentrant = E.observe edges (fun _ -> success) in
  let before = execution.Execution.entries in
  (match
     Execution.run execution (fun _checkpoint ->
         E.publish edges reentrant 5;
         Ok ())
   with
  | Ok () -> ()
  | Error _ -> assert false);
  check "nested same-fiber claim reacquired execution"
    (execution.Execution.entries = before + 1);
  check "nested same-fiber publication was lost"
    (E.run edges ~runtime:1 ~plan:[ E.Observer reentrant ] = Ok ());
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
  let source_admissions = ref 0 in
  check "timer wake did not admit source work once"
    (E.timer_wake_with edges ~runtime:7 timer
       ~generation:(E.timer_generation timer)
       ~admit:(fun () -> incr source_admissions)
     = Ok true
     && !source_admissions = 1);
  let catch_up ~current ~now_ms ~next_due_ms ~interval_ms =
    if now_ms < next_due_ms then current
    else
      let elapsed = now_ms - next_due_ms in
      let ticks = 1 + (elapsed / interval_ms) in
      if ticks > max_int - current then max_int else current + ticks
  in
  check "interval catch-up did not advance arithmetically"
    (catch_up ~current:0 ~now_ms:50 ~next_due_ms:10 ~interval_ms:10 = 5);
  check "interval catch-up did not saturate"
    (catch_up ~current:(max_int - 2) ~now_ms:50 ~next_due_ms:10
       ~interval_ms:10
     = max_int);
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
  let race_execution = Execution.create () in
  let race_edges = E.create race_execution in
  let sleepers = ref 0 in
  let finish_count = ref 0 in
  let registration = ref None in
  let installing = ref None in
  let race_policy =
    E.
      {
        same_runtime = Int.equal;
        start =
          (fun _ ~generation:_ ->
            incr sleepers;
            E.abort_timer_registration race_edges
              (Option.get !installing)
              (Option.get !registration) E.Disposed;
            Success
              (fun () ->
                decr sleepers;
                success));
      }
  in
  let race_timer =
    E.create_timer race_edges ~runtime:9 ~policy:race_policy
  in
  installing := Some race_timer;
  let race_observer =
    E.observe race_edges
      ~finish:(fun _ ->
        check "finish ran before stop-before-install cleanup" (!sleepers = 0);
        incr finish_count;
        success)
      (fun _ -> success)
  in
  registration := Some race_observer;
  E.activate_timer_registration race_edges race_timer race_observer;
  bounded "dispose before cancel installation" 3
    (fun () ->
      ignore (E.run race_edges ~runtime:9 ~plan:[]))
    (fun () ->
      !sleepers = 0 && !finish_count = 1
      && E.queued_timer_count race_edges = 0);
  let failure_execution = Execution.create () in
  let failure_edges = E.create failure_execution in
  let leaked_sleepers = ref 0 in
  let cleanup_calls = ref 0 in
  let failed_policy =
    E.
      {
        same_runtime = Int.equal;
        start =
          (fun _ ~generation:_ ->
            incr leaked_sleepers;
            interrupted);
      }
  in
  let failed_timer =
    E.create_timer_with_cleanup failure_edges ~runtime:10
      ~policy:failed_policy
      ~on_start_failure:(fun ~generation:_ _ ->
        incr cleanup_calls;
        decr leaked_sleepers;
        success)
  in
  let failed_observer =
    E.observe failure_edges (fun _ -> success)
  in
  E.activate_timer_registration failure_edges failed_timer failed_observer;
  (match E.run failure_edges ~runtime:10 ~plan:[] with
  | Error (E.Cleanup_failures [ E.Interrupted Interrupted ]) -> ()
  | _ -> failwith "interrupted start did not preserve classification");
  check "start failure leaked sleeper"
    (!leaked_sleepers = 0 && !cleanup_calls = 1);
  E.abort_timer_registration failure_edges failed_timer failed_observer
    E.Disposed;
  bounded "cancelled registration rollback" 3
    (fun () ->
      ignore (E.run failure_edges ~runtime:10 ~plan:[]))
    (fun () -> E.queued_timer_count failure_edges = 0);
  let raised_sleepers = ref 0 in
  let raised_cleanup = ref 0 in
  let raised_timer =
    E.create_timer_with_cleanup failure_edges ~runtime:10
      ~policy:
        E.
          {
            same_runtime = Int.equal;
            start =
              (fun _ ~generation:_ ->
                incr raised_sleepers;
                raise Interrupted);
          }
      ~on_start_failure:(fun ~generation:_ _ ->
        incr raised_cleanup;
        decr raised_sleepers;
        success)
  in
  E.set_timer_demand failure_edges raised_timer true;
  (match E.run failure_edges ~runtime:10 ~plan:[] with
  | exception Interrupted -> ()
  | _ -> failwith "raised start interruption changed classification");
  check "raised start interruption skipped protected cleanup"
    (!raised_sleepers = 0 && !raised_cleanup = 1);
  E.set_timer_demand failure_edges raised_timer false;
  bounded "raised start rollback" 2
    (fun () ->
      ignore (E.run failure_edges ~runtime:10 ~plan:[]))
    (fun () -> E.queued_timer_count failure_edges = 0);
  let batch_execution = Execution.create () in
  let batch_edges = E.create batch_execution in
  let sibling_starts = ref 0 in
  let failed_starts = ref 0 in
  let installed_sleepers = ref 0 in
  let compensations = ref 0 in
  let sibling =
    E.create_timer batch_edges ~runtime:11
      ~policy:
        E.
          {
            same_runtime = Int.equal;
            start =
              (fun _ ~generation:_ ->
                incr sibling_starts;
                incr installed_sleepers;
                Success
                  (fun () ->
                    incr compensations;
                    decr installed_sleepers;
                    success));
          }
  in
  let failed =
    E.create_timer batch_edges ~runtime:11
      ~policy:
        E.
          {
            same_runtime = Int.equal;
            start =
              (fun _ ~generation:_ ->
                incr failed_starts;
                defect "batch-start");
          }
  in
  E.set_timer_demand batch_edges sibling true;
  E.set_timer_demand batch_edges failed true;
  (match E.run batch_edges ~runtime:11 ~plan:[] with
  | Error (E.Cleanup_failures [ E.Defect (Injected "batch-start") ]) -> ()
  | _ -> failwith "multi-start failure result mismatch");
  check "multi-start batch did not compensate installed sibling"
    (!sibling_starts = 1 && !failed_starts = 1
     && !compensations = 1 && !installed_sleepers = 0);
  check "multi-start failure lost later intents"
    (E.queued_timer_count batch_edges = 2);
  check "cleanup-only drain claimed ordinary timer mismatches"
    (E.drain_cleanup batch_edges = Ok ()
     && !sibling_starts = 1 && !failed_starts = 1
     && E.queued_timer_count batch_edges = 2);
  let order_edges = E.create (Execution.create ()) in
  let attempts = ref [] in
  let successful name compensation =
    E.create_timer order_edges ~runtime:12
      ~policy:
        E.
          {
            same_runtime = Int.equal;
            start =
              (fun _ ~generation:_ ->
                attempts := name :: !attempts;
                Success (fun () -> defect compensation));
          }
  in
  let first = successful "first" "comp-first" in
  let middle =
    E.create_timer order_edges ~runtime:12
      ~policy:
        E.
          {
            same_runtime = Int.equal;
            start =
              (fun _ ~generation:_ ->
                attempts := "middle" :: !attempts;
                defect "start-middle");
          }
  in
  let last = successful "last" "comp-last" in
  List.iter
    (fun timer -> E.set_timer_demand order_edges timer true)
    [ first; middle; last ];
  (match E.run order_edges ~runtime:12 ~plan:[] with
  | Error
      (E.Cleanup_failures
        [
          E.Defect (Injected "start-middle");
          E.Defect (Injected "comp-first");
          E.Defect (Injected "comp-last");
        ]) ->
      ()
  | _ -> failwith "compensation failures were not aggregated in order");
  check "start batch stopped after first failure"
    (List.rev !attempts = [ "first"; "middle"; "last" ]);
  let stop_edges = E.create (Execution.create ()) in
  let stop_attempts = ref 0 in
  let stop_timer =
    E.create_timer stop_edges ~runtime:13
      ~policy:
        E.
          {
            same_runtime = Int.equal;
            start =
              (fun _ ~generation:_ ->
                Success
                  (fun () ->
                    incr stop_attempts;
                    defect "ordinary-stop"));
          }
  in
  E.set_timer_demand stop_edges stop_timer true;
  check "ordinary stop setup failed"
    (E.run stop_edges ~runtime:13 ~plan:[] = Ok ());
  E.set_timer_demand stop_edges stop_timer false;
  (match E.run stop_edges ~runtime:13 ~plan:[] with
  | Error (E.Cleanup_failures [ E.Defect (Injected "ordinary-stop") ]) -> ()
  | _ -> failwith "ordinary stop failure result mismatch");
  check "failed stop retried in the same run" (!stop_attempts = 1);
  check "cleanup-only drain retried failed stop"
    (E.drain_cleanup stop_edges = Ok ()
     && !stop_attempts = 1
     && E.queued_timer_count stop_edges = 1);
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
