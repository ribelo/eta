(** Concurrent combinators: [par], [par_pair], [par_collect], [race], [all],
    [all_settled], [for_each_par], [for_each_par_bounded]. Internal: see Effect
    for the public surface. *)

open Effect_core

let run_child frame sw effect =
  let child_frame = { frame with sw } in
  frame.runtime.tracer#with_fiber_context @@ fun () -> run_to_exit child_frame effect

(** Run a list of side-effecting forks in parallel under a fresh switch.

    Each fork is a [unit -> unit] thunk responsible for its own slot-write or
    promise-resolution. The helper owns:

    - cancellation: a [Stop] exception fails the switch as soon as any fork
      raises, interrupting the rest;
    - cause aggregation: every fork that raises gets its exception captured as a
      [Cause.t];
    - assembly: when no fork raised, [assemble ()] is called to build the
      success value.

    This is the shared backbone of [par_pair], [par_collect], [for_each_par],
    and [for_each_par_bounded]. *)
let par_run_forks frame ~forks ~assemble =
  let causes = ref [] in
  let exception Stop in
  (try
     switch_run frame @@ fun par_sw ->
     List.iter
       (fun fork ->
         fiber_fork frame ~sw:par_sw (fun () ->
             frame.runtime.tracer#with_fiber_context @@ fun () ->
             try fork ()
             with exn ->
               let cause =
                 Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
               in
               causes := cause :: !causes;
               (try switch_fail frame par_sw Stop with _ -> ())))
       forks
   with Stop -> ());
  match List.rev !causes with
  | [] -> ok (assemble ())
  | causes -> error (Cause.concurrent causes)

let par_collect frame tasks =
  let n = List.length tasks in
  let results = Array.make n None in
  let forks =
    List.mapi (fun index task () -> results.(index) <- Some (task ())) tasks
  in
  par_run_forks frame ~forks
    ~assemble:(fun () -> Array.to_list results |> List.map Option.get)

let race_eval effects () =
  let frame = current_frame () in
  match effects with
  | [] -> invalid_arg "Effect.race: empty list"
  | _ ->
      let winner = ref None in
      let causes = ref [] in
      let exception Race_won in
      (try
         switch_run frame @@ fun race_sw ->
         let results = Eio.Stream.create (List.length effects) in
         List.iter
           (fun effect ->
             fiber_fork frame ~sw:race_sw (fun () ->
                 Eio.Stream.add results (run_child frame race_sw effect)))
           effects;
         let rec collect failed remaining =
           if remaining = 0 then causes := List.rev failed
           else
             match Eio.Stream.take results with
             | Exit.Ok value ->
                 winner := Some value;
                 switch_fail frame race_sw Race_won;
                 fiber_await_cancel frame
             | Exit.Error cause -> collect (cause :: failed) (remaining - 1)
         in
         collect [] (List.length effects)
      with Race_won -> ());
      (match !winner with
      | Some value -> ok value
      | None -> error (Cause.concurrent !causes))

let race effects = make ~names:(concat_names effects) (race_eval effects)

type ('a, 'b) par_pair = { left : 'a; right : 'b }

let par_pair frame left right =
  let left_result, left_resolver = Eio.Promise.create () in
  let right_result, right_resolver = Eio.Promise.create () in
  par_run_forks frame
    ~forks:
      [
        (fun () -> Eio.Promise.resolve left_resolver (run_to_value frame left));
        (fun () -> Eio.Promise.resolve right_resolver (run_to_value frame right));
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

let par left right = make ~names:(left.names @ right.names) (par_eval left right)

let all_eval effects () =
  let frame = current_frame () in
  par_collect frame (List.map (fun effect () -> run_to_value frame effect) effects)

let all effects = make ~names:(concat_names effects) (all_eval effects)

let all_settled_eval effects () =
  let frame = current_frame () in
  let results = Array.make (List.length effects) None in
  switch_run frame (fun sw ->
      List.iteri
        (fun index effect ->
          fiber_fork frame ~sw (fun () ->
              results.(index) <-
                Some
                  (match run_child frame sw effect with
                  | Exit.Ok value -> Ok value
                  | Exit.Error cause -> Error cause)))
        effects);
  ok (Array.to_list results |> List.map Option.get)

let all_settled effects =
  make ~names:(concat_names effects) (all_settled_eval effects)

(** Worker-pool variant: [workers] forks share an atomic counter, each pulling
    the next task off [tasks] until the index reaches [n]. Wrapping the worker
    body in [with_frame] is required because each [task.eval ()] call uses
    [current_frame ()] internally. *)
let for_each_par_workers frame ~workers ~tasks ~n =
  let results = Array.make n None in
  let next = P_atomic.make 0 in
  let run_task effect =
    exit_to_value frame
      (try effect.eval () with exn -> exit_of_exn frame exn)
  in
  let worker () =
    with_frame frame @@ fun () ->
    let rec loop () =
      let i = P_atomic.fetch_and_add next 1 in
      if i < n then begin
        results.(i) <- Some (run_task (Array.unsafe_get tasks i));
        loop ()
      end
    in
    loop ()
  in
  let forks = List.init workers (fun _ -> worker) in
  par_run_forks frame ~forks
    ~assemble:(fun () -> Array.to_list results |> List.map Option.get)

let for_each_par xs f =
  let n = List.length xs in
  let xs_arr = Array.of_list xs in
  let tasks = Array.map f xs_arr in
  make @@ fun () ->
  let frame = current_frame () in
  let workers = min n 8 in
  for_each_par_workers frame ~workers ~tasks ~n

let for_each_par_bounded ~max xs f =
  if max <= 0 then invalid_arg "Effect.for_each_par_bounded: max must be > 0";
  let n = List.length xs in
  let xs_arr = Array.of_list xs in
  let tasks = Array.map f xs_arr in
  make @@ fun () ->
  let frame = current_frame () in
  let workers = min max n in
  for_each_par_workers frame ~workers ~tasks ~n
