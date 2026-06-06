(** Concurrent combinators: [par], [par_pair], [par_collect], [race], [all],
    [all_settled], [for_each_par], [for_each_par_bounded]. Internal: see Effect
    for the public surface. *)

open Effect_core

let run_child ?internal_cancel frame sw eff =
  frame.runtime.tracer#with_fiber_context @@ fun () ->
  run_scope ?internal_cancel ~sw frame eff

let atomic_push cell value =
  let rec loop () =
    let values = Atomic.get cell in
    if not (Atomic.compare_and_set cell values (value :: values)) then loop ()
  in
  loop ()

let missing_result name index =
  failwith (Printf.sprintf "%s: child %d did not publish a result" name index)

let collect_results name results =
  Array.to_list
    (Array.mapi
       (fun index -> function
         | Some value -> value
         | None -> missing_result name index)
       results)

let rec has_finalizer_diagnostic = function
  | Cause.Finalizer _ | Cause.Suppressed { finalizer = _; _ } -> true
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists has_finalizer_diagnostic causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false

let cause_of_list = function
  | [] -> invalid_arg "Effect.race: empty diagnostic cause list"
  | [ cause ] -> cause
  | causes -> Cause.concurrent causes

let rec is_interrupt_with_id : type err. Cause.interrupt_id -> err Cause.t -> bool =
 fun expected -> function
  | Cause.Interrupt (Some actual) -> Cause.equal_interrupt_id actual expected
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.for_all (is_interrupt_with_id expected) causes
  | Cause.Fail _ | Cause.Die _ | Cause.Interrupt None | Cause.Finalizer _
  | Cause.Suppressed _ ->
      false

(** Run side-effecting forks under one switch and aggregate child causes. *)
let par_run_forks frame ~forks ~assemble =
  let causes = Atomic.make [] in
  let stopping = Atomic.make false in
  let exception Stop in
  let stop_id = Cause.fresh_interrupt_id () in
  let internal_cancel =
    {
      interrupt_id = stop_id;
      matches_cancel = (function Stop -> true | _ -> false);
    }
  in
  let stop_once par_sw =
    if Atomic.compare_and_set stopping false true then
      try switch_fail frame par_sw Stop with _ -> ()
  in
  (try
     switch_run frame @@ fun par_sw ->
     List.iter
      (fun fork ->
         fiber_fork frame ~sw:par_sw (fun () ->
             frame.runtime.tracer#with_fiber_context @@ fun () ->
             try fork internal_cancel par_sw
             with exn ->
               let cause =
                 Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
               in
               if not (is_interrupt_with_id stop_id cause) then
                 atomic_push causes cause;
               stop_once par_sw))
       forks
   with Stop -> ());
  match List.rev (Atomic.get causes) with
  | [] -> ok (assemble ())
  | causes -> error (Cause.concurrent causes)

let par_collect frame ~name tasks =
  let n = List.length tasks in
  let results = Array.make n None in
  let forks =
    List.mapi
      (fun index task internal_cancel sw ->
        results.(index) <- Some (task internal_cancel sw))
      tasks
  in
  par_run_forks frame ~forks ~assemble:(fun () -> collect_results name results)

let race_eval effects () =
  let frame = current_frame () in
  match effects with
  | [] -> invalid_arg "Effect.race: empty list"
  | _ ->
      let winner = ref None in
      let causes = ref [] in
      let results = Eio.Stream.create (List.length effects) in
      let exception Race_won in
      let rec has_race_won = function
        | Race_won -> true
        | Eio.Exn.Multiple causes ->
            List.exists (fun (exn, _bt) -> has_race_won exn) causes
        | _ -> false
      in
      let rec causes_without_race_won = function
        | Race_won -> []
        | Eio.Exn.Multiple causes ->
            List.concat_map
              (fun (exn, bt) ->
                match exn with
                | Race_won -> []
                | Eio.Exn.Multiple _ -> causes_without_race_won exn
                | _ ->
                    [
                      Runtime_core.cause_of_exn ~backtrace:bt
                        ~capture_backtrace:frame.runtime.capture_backtrace
                        frame.fail_key exn;
                    ])
              causes
        | exn ->
            [ Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn ]
      in
      (try
         switch_run frame @@ fun race_sw ->
         List.iter
           (fun eff ->
             fiber_fork frame ~sw:race_sw (fun () ->
                 Eio.Stream.add results (run_child frame race_sw eff)))
           effects;
         let rec drain_cancelled_losers acc remaining =
           if remaining = 0 then List.rev acc
           else
             match Eio.Stream.take results with
             | Exit.Error cause when has_finalizer_diagnostic cause ->
                 drain_cancelled_losers (cause :: acc) (remaining - 1)
             | Exit.Error _ | Exit.Ok _ ->
                 drain_cancelled_losers acc (remaining - 1)
         in
         let rec collect failed remaining =
           if remaining = 0 then causes := List.rev failed
           else
             match Eio.Stream.take results with
             | Exit.Ok value ->
                 winner := Some value;
                 (* Once a winner has produced side effects and published its
                    value, outer cancellation must not discard that value while
                    loser cleanup runs. The loser switch is still failed
                    immediately; cancellation is deferred only for the
                    post-winner cleanup window. *)
                 switch_fail frame race_sw Race_won;
                 let diagnostics = ref [] in
                 (try
                    Runtime_core.cancel_protect (fun () ->
                        diagnostics :=
                          drain_cancelled_losers [] (remaining - 1))
                  with
                  | Eio.Cancel.Cancelled _ | Race_won -> ());
                 causes := List.rev_append !diagnostics !causes;
                 raise Race_won
             | Exit.Error cause -> collect (cause :: failed) (remaining - 1)
         in
         collect [] (List.length effects)
      with
      | Race_won -> ()
      | exn when has_race_won exn ->
          (* Eio may aggregate the internal Race_won escape with simultaneous
             switch-level failures. Race_won is only a control signal used to
             stop losers after a winner has been stored; it must never leak as
             a public Die cause. Ordinary loser failures remain ignored by race
             semantics, while finalizer diagnostics below are still surfaced. *)
          causes := List.rev_append (causes_without_race_won exn) !causes);
      (match !winner with
      | Some value ->
          let rec drain_diagnostics acc =
            match Eio.Stream.take_nonblocking results with
            | Some (Exit.Error cause) when has_finalizer_diagnostic cause ->
                drain_diagnostics (cause :: acc)
            | Some _ -> drain_diagnostics acc
            | None -> List.rev acc
          in
          (match drain_diagnostics [] with
          | [] ->
              let switch_diagnostics =
                List.filter has_finalizer_diagnostic !causes
              in
              if switch_diagnostics = [] then ok value
              else error (cause_of_list switch_diagnostics)
          | diagnostics ->
              (* Ordinary loser failures are ignored by race semantics, but
                 cleanup/finalizer failures produced while cancelling losers
                 are diagnostics, not alternative race results. Surface them
                 instead of returning a successful winner with hidden leaks. *)
              error (cause_of_list diagnostics))
      | None -> error (Cause.concurrent !causes))

let race effects = make ~names:(concat_names effects) (race_eval effects)

type ('a, 'b) par_pair = { left : 'a; right : 'b }

let par_pair frame left right =
  let left_result, left_resolver = Eio.Promise.create () in
  let right_result, right_resolver = Eio.Promise.create () in
  par_run_forks frame
    ~forks:
      [
        (fun internal_cancel sw ->
          Eio.Promise.resolve left_resolver
            (exit_to_value frame
               (run_child ~internal_cancel frame sw left)));
        (fun internal_cancel sw ->
          Eio.Promise.resolve right_resolver
            (exit_to_value frame
               (run_child ~internal_cancel frame sw right)));
      ]
    ~assemble:(fun () ->
      {
        left = Eio.Promise.await left_result;
        right = Eio.Promise.await right_result;
      })

let par_eval left right () =
  let frame = current_frame () in
  match par_pair frame left right with
  | Exit.Ok { left; right } -> ok (left, right)
  | Exit.Error cause -> error cause

let par left right =
  make ~names:(names left @ names right) (par_eval left right)

let all_eval effects () =
  let frame = current_frame () in
  par_collect frame ~name:"Effect.all"
    (List.map
       (fun eff internal_cancel sw ->
         exit_to_value frame (run_child ~internal_cancel frame sw eff))
       effects)

let all effects = make ~names:(concat_names effects) (all_eval effects)

let all_settled_eval effects () =
  let frame = current_frame () in
  let results = Array.make (List.length effects) None in
  switch_run frame (fun sw ->
      List.iteri
        (fun index eff ->
          fiber_fork frame ~sw (fun () ->
              results.(index) <-
                Some
                  (match run_child frame sw eff with
                  | Exit.Ok value -> Ok value
                  | Exit.Error cause -> Error cause)))
        effects);
  ok (collect_results "Effect.all_settled" results)

let all_settled effects =
  make ~names:(concat_names effects) (all_settled_eval effects)

(** Worker-pool variant: [workers] forks share an atomic counter, each pulling
    the next task off [tasks] until the index reaches [n]. Wrapping the worker
    body in [with_frame] is required because each [task.eval ()] call uses
    [current_frame ()] internally. *)
let for_each_par_workers frame ~name ~workers ~tasks ~n =
  let results = Array.make n None in
  let next = P_atomic.make 0 in
  let run_task internal_cancel sw eff =
    exit_to_value frame (run_child ~internal_cancel frame sw eff)
  in
  let worker internal_cancel sw =
    let rec loop () =
      let i = P_atomic.fetch_and_add next 1 in
      if i < n then begin
        results.(i) <-
          Some (run_task internal_cancel sw (Array.unsafe_get tasks i));
        loop ()
      end
    in
    loop ()
  in
  let forks = List.init workers (fun _ -> worker) in
  par_run_forks frame ~forks ~assemble:(fun () -> collect_results name results)

let for_each_par xs (f) =
  let n = List.length xs in
  let xs_arr = Array.of_list xs in
  let tasks = Array.map f xs_arr in
  make @@ fun () ->
  let frame = current_frame () in
  let workers = min n 8 in
  for_each_par_workers frame ~name:"Effect.for_each_par" ~workers ~tasks ~n

let for_each_par_bounded ~max xs (f) =
  if max <= 0 then invalid_arg "Effect.for_each_par_bounded: max must be > 0";
  let n = List.length xs in
  let xs_arr = Array.of_list xs in
  let tasks = Array.map f xs_arr in
  make @@ fun () ->
  let frame = current_frame () in
  let workers = min max n in
  for_each_par_workers frame ~name:"Effect.for_each_par_bounded" ~workers
    ~tasks ~n
