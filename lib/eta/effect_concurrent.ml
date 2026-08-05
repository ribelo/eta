(** Concurrent combinators: [par], [par_pair], [race], [all], [all_bounded],
    [all_settled], [map_par], [acquire_all_par]. Bounded admission:
    [collect_workers]. Internal: see Effect for the public surface. *)

open Effect_core

let with_task_context frame f =
  let _, tracer = Runtime_core.current_tracer frame.runtime in
  tracer#with_task_context frame.runtime.contract f

let run_child ?internal_cancel frame sw eff =
  with_task_context frame @@ fun () ->
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

(** Register every fork behind one start promise, then release them together.
    Backends may run a newly forked fiber immediately, so the promise wait must
    be the wrapper's first action. *)
let fork_after_registration frame ~sw forks =
  let contract = frame.runtime.contract in
  let #(start, release) =
      contract.Runtime_contract.create_promise () in
  List.iter
    (fun fork ->
      fiber_fork frame ~sw (fun () ->
          contract.Runtime_contract.await_promise start;
          contract.Runtime_contract.check ();
          fork ()))
    forks;
  contract.Runtime_contract.resolve_promise release ()

(** Run side-effecting forks under one switch and aggregate child causes. *)
let par_run_forks ?(start_after_registration = false) frame ~forks ~assemble =
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
     let runs =
       List.map
         (fun fork () ->
           try fork internal_cancel par_sw
           with exn ->
             let cause =
               Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
             in
             if not (is_interrupt_with_id stop_id cause) then
               atomic_push causes cause;
             stop_once par_sw)
         forks
     in
     if start_after_registration then
       fork_after_registration frame ~sw:par_sw runs
     else List.iter (fiber_fork frame ~sw:par_sw) runs
   with Stop -> ());
  match List.rev (Atomic.get causes) with
  | [] -> ok (assemble ())
  | causes -> error (Cause.concurrent causes)

let race_eval effects frame =
  match effects with
  | [] -> invalid_arg "Effect.race: empty list"
  | _ ->
      let winner = ref None in
      let causes = ref [] in
      let contract = frame.runtime.contract in
      let results = contract.Runtime_contract.create_stream (List.length effects) in
      let exception Race_won in
      let rec has_race_won = function
        | Race_won -> true
        | exn -> (
            match contract.Runtime_contract.multiple_exceptions exn with
            | Some causes ->
                List.exists (fun (exn, _bt) -> has_race_won exn) causes
            | None -> false)
      in
      let rec causes_without_race_won = function
        | Race_won -> []
        | exn ->
            (match contract.Runtime_contract.multiple_exceptions exn with
             | Some causes ->
                 List.concat_map
                   (fun (exn, bt) ->
                     match exn with
                     | Race_won -> []
                     | _ when has_race_won exn -> causes_without_race_won exn
                     | _ ->
                         [
                           Runtime_core.cause_of_exn_runtime ~backtrace:bt
                             frame.runtime frame.fail_key exn;
                         ])
                   causes
             | None ->
                 [
                   Runtime_core.cause_of_exn_runtime frame.runtime
                     frame.fail_key exn;
                 ])
      in
      (try
         switch_run frame @@ fun race_sw ->
         List.iter
           (fun eff ->
            fiber_fork frame ~sw:race_sw (fun () ->
                 contract.Runtime_contract.stream_add results
                   (run_child frame race_sw eff)))
           effects;
         let rec drain_cancelled_losers acc remaining =
           if remaining = 0 then List.rev acc
           else
             match contract.Runtime_contract.stream_take results with
             | Exit.Error cause when has_finalizer_diagnostic cause ->
                 drain_cancelled_losers (cause :: acc) (remaining - 1)
             | Exit.Error _ | Exit.Ok _ ->
                 drain_cancelled_losers acc (remaining - 1)
         in
         let rec collect failed remaining =
           if remaining = 0 then causes := List.rev failed
           else
             match contract.Runtime_contract.stream_take results with
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
                    frame.runtime.contract.Runtime_contract.protect (fun () ->
                        diagnostics :=
                          drain_cancelled_losers [] (remaining - 1))
                  with exn ->
                    if
                      Option.is_some
                        (contract.Runtime_contract.cancellation_reason exn)
                    then ()
                    else
                      match exn with
                      | Race_won -> ()
                      | exn -> raise exn);
                 causes := List.rev_append !diagnostics !causes;
                 raise Race_won
             | Exit.Error cause -> collect (cause :: failed) (remaining - 1)
         in
         collect [] (List.length effects)
      with
      | Race_won -> ()
      | exn when has_race_won exn ->
          (* A runtime may aggregate the internal Race_won escape with
             simultaneous switch-level failures. Race_won is only a control
             signal used to stop losers after a winner has been stored; it must
             never leak as a public Die cause. Ordinary loser failures remain
             ignored by race semantics, while finalizer diagnostics below are
             still surfaced. *)
          causes := List.rev_append (causes_without_race_won exn) !causes);
      (match !winner with
      | Some value ->
          let rec drain_diagnostics acc =
            match contract.Runtime_contract.stream_take_nonblocking results with
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

let race effects =
  make ~leaf_name:"Effect.race" (race_eval effects)

type ('a, 'b) par_pair = { left : 'a; right : 'b }

let par_pair frame left right =
  let contract = frame.runtime.contract in
  let #(left_result, left_resolver) =
      contract.Runtime_contract.create_promise ()
  in
  let #(right_result, right_resolver) =
      contract.Runtime_contract.create_promise ()
  in
  par_run_forks frame
    ~forks:
      [
        (fun internal_cancel sw ->
          contract.Runtime_contract.resolve_promise left_resolver
            (exit_to_value frame
               (run_child ~internal_cancel frame sw left)));
        (fun internal_cancel sw ->
          contract.Runtime_contract.resolve_promise right_resolver
            (exit_to_value frame
               (run_child ~internal_cancel frame sw right)));
      ]
    ~assemble:(fun () ->
      {
        left = contract.Runtime_contract.await_promise left_result;
        right = contract.Runtime_contract.await_promise right_result;
      })

let par_eval left right frame =
  match par_pair frame left right with
  | Exit.Ok { left; right } -> ok (left, right)
  | Exit.Error cause -> error cause

let par left right =
  make ~leaf_name:"Effect.par" (par_eval left right)

(** Fork [effect] as a child that publishes its exit to a fresh promise; the
    returned [await] reads the published value once [par_run_forks] has
    confirmed every child finished. A failing child raises through
    {!exit_to_value} inside its fork, where [par_run_forks] aggregates the
    cause and cancels the siblings, so [await] is only called for children
    that actually published. *)
let promise_fork frame eff =
  let contract = frame.runtime.contract in
  let #(result, resolver) =
      contract.Runtime_contract.create_promise () in
  let fork internal_cancel sw =
    contract.Runtime_contract.resolve_promise resolver
      (exit_to_value frame (run_child ~internal_cancel frame sw eff))
  in
  let await () = contract.Runtime_contract.await_promise result in
  (fork, await)

let par3_eval left middle right frame =
  let left_fork, await_left = promise_fork frame left in
  let middle_fork, await_middle = promise_fork frame middle in
  let right_fork, await_right = promise_fork frame right in
  match
    par_run_forks frame
      ~forks:[ left_fork; middle_fork; right_fork ]
      ~assemble:(fun () -> (await_left (), await_middle (), await_right ()))
  with
  | Exit.Ok (left, middle, right) -> ok (left, middle, right)
  | Exit.Error cause -> error cause

let par3 left middle right =
  make ~leaf_name:"Effect.par3" (par3_eval left middle right)

let par4_eval first second third fourth frame =
  let first_fork, await_first = promise_fork frame first in
  let second_fork, await_second = promise_fork frame second in
  let third_fork, await_third = promise_fork frame third in
  let fourth_fork, await_fourth = promise_fork frame fourth in
  match
    par_run_forks frame
      ~forks:[ first_fork; second_fork; third_fork; fourth_fork ]
      ~assemble:(fun () ->
        (await_first (), await_second (), await_third (), await_fourth ()))
  with
  | Exit.Ok (first, second, third, fourth) -> ok (first, second, third, fourth)
  | Exit.Error cause -> error cause

let par4 first second third fourth =
  make ~leaf_name:"Effect.par4" (par4_eval first second third fourth)

let all_settled_eval effects frame =
  let results = Array.make (List.length effects) None in
  switch_run frame (fun sw ->
      List.mapi
        (fun index eff () ->
          results.(index) <-
            Some
              (match run_child frame sw eff with
              | Exit.Ok value -> Ok value
              | Exit.Error cause -> Error cause))
        effects
      |> fork_after_registration frame ~sw);
  ok (collect_results "Effect.all_settled" results)

let all_settled effects =
  make ~leaf_name:"Effect.all_settled" (all_settled_eval effects)

(** [workers] forks share an atomic counter, each pulling the next input until
    the index reaches [n]. The parent frame is passed explicitly into each
    effect evaluation. *)
let collect_workers frame ~name ~workers ~inputs ~f ~n =
  let results = Array.make n None in
  let next = P_atomic.make 0 in
  let worker internal_cancel sw =
    let rec loop () =
      let i = P_atomic.fetch_and_add next 1 in
      if i < n then begin
        let eff = f (Array.unsafe_get inputs i) in
        results.(i) <-
          Some (exit_to_value frame (run_child ~internal_cancel frame sw eff));
        loop ()
      end
    in
    loop ()
  in
  let forks = List.init workers (fun _ -> worker) in
  par_run_forks frame ~forks
    ~assemble:(fun () -> collect_results name results)

let all_eval effects frame =
  let results = Array.make (List.length effects) None in
  let forks =
    List.mapi
      (fun index eff internal_cancel sw ->
        results.(index) <-
          Some (exit_to_value frame (run_child ~internal_cancel frame sw eff)))
      effects
  in
  par_run_forks ~start_after_registration:true frame ~forks
    ~assemble:(fun () -> collect_results "Effect.all" results)

let all effects =
  make ~leaf_name:"Effect.all" (all_eval effects)

let all_bounded ~max_concurrent effects =
  if max_concurrent <= 0 then
    invalid_arg "Effect.all_bounded: max_concurrent must be > 0";
  let inputs = Array.of_list effects in
  let n = Array.length inputs in
  make ~leaf_name:"Effect.all_bounded" @@ fun frame ->
  collect_workers frame ~name:"Effect.all_bounded"
    ~workers:(min max_concurrent n) ~inputs ~f:Fun.id ~n

let map_par ?(max_concurrent = 8) f xs =
  if max_concurrent <= 0 then
    invalid_arg "Effect.map_par: max_concurrent must be > 0";
  let inputs = Array.of_list xs in
  let n = Array.length inputs in
  make ~leaf_name:"Effect.map_par" @@ fun frame ->
  collect_workers frame ~name:"Effect.map_par"
    ~workers:(min max_concurrent n) ~inputs ~f ~n

let acquire_one owner staging release acquire =
  preserve ~leaf_name:"Effect.acquire_all_par.acquire" acquire @@ fun frame ->
  frame.runtime.contract.Runtime_contract.check ();
  match eval frame acquire with
  | Exit.Error _ as error -> error
  | Exit.Ok resource ->
      staging.finalizers :=
        (fun () -> run_scope_value owner (release resource))
        :: !(staging.finalizers);
      (* Cancellation after acquisition is observed only after rollback has
         been armed. A late completion therefore stays in the staging scope. *)
      fiber_yield frame;
      ok resource

let acquire_all_par ?(max_concurrent = 8) ~acquire ~release configs =
  if max_concurrent <= 0 then
    invalid_arg "Effect.acquire_all_par: max_concurrent must be > 0";
  let inputs = Array.of_list configs in
  let n = Array.length inputs in
  make ~leaf_name:"Effect.acquire_all_par" @@ fun owner ->
  run_scope_body owner @@ fun staging ->
  let resources =
    collect_workers staging ~name:"Effect.acquire_all_par"
      ~workers:(min max_concurrent n) ~inputs
      ~f:(fun config -> acquire_one owner staging release (acquire config)) ~n
    |> exit_to_value staging
  in
  (* Check once more before the non-suspending batch commit. Build the final
     stack before mutating either scope so allocation failure still rolls back. *)
  staging.runtime.contract.Runtime_contract.check ();
  let transferred = !(staging.finalizers) @ !(owner.finalizers) in
  owner.finalizers := transferred;
  staging.finalizers := [];
  resources
