(* Post_commit: opaque post-commit settlement.

 Invariant: observer claims, acknowledgements, timer generations, cleanup,
 and stream acknowledgements are settled only inside this driver.

 DAG: Propagation and Post_commit are independent leaves; Graph composes
 both. This module must not reference Propagation, Graph, or Eta. *)

type 'error failure =
  | Typed_failure of 'error
  | Defect of exn
  | Interrupted of exn

type ('a, 'error) outcome = Success of 'a | Failure of 'error failure
type ('a : value_or_null) update =
  | Initialized of 'a
  | Changed of 'a * 'a
type finish_reason = Disposed | Invalid_scope
type lifecycle = Active | Finished of finish_reason

type stats = {
  timer_claims : int;
  callback_claims : int;
  acknowledgements : int;
  releases : int;
}

type mutable_stats = {
  mutable timer_claims : int;
  mutable callback_claims : int;
  mutable acknowledgements : int;
  mutable releases : int;
}

type ('a : value_or_null) cursor =
  | Never_delivered
  | Delivered of 'a
  | Pending of int * 'a update
  | Running of int * 'a update

type ('a : value_or_null) observer = {
  owner : t;
  mutable lifecycle : lifecycle;
  mutable cursor : 'a cursor;
  callback : 'a delivery -> (unit, Obj.t) outcome;
  finish : finish_reason -> (unit, Obj.t) outcome;
}

and ('a : value_or_null) delivery = {
  observer : 'a observer;
  token : int;
  event : 'a update;
  mutable acknowledged : bool;
}

and packed_observer =
  | Observer : ('a : value_or_null). 'a observer -> packed_observer

and hook =
  | Hook : (unit -> (unit, 'error) outcome) -> hook

and packed_timer =
  | Timer : ('runtime, 'error) timer -> packed_timer

and t = {
  mutable next_token : int;
  hooks : hook Queue.t;
  timer_hooks : hook Queue.t;
  timers : packed_timer Queue.t;
  counts : mutable_stats;
}

and ('runtime, 'error) timer_policy = {
  same_runtime : 'runtime -> 'runtime -> bool;
  start :
    'runtime ->
    generation:int ->
    ((unit -> (unit, 'error) outcome), 'error) outcome;
}

and ('runtime, 'error) timer_state =
  | Inactive
  | Starting of int
  | Running of int * (unit -> (unit, 'error) outcome)

and ('runtime, 'error) timer = {
  owner : t;
  runtime : 'runtime;
  policy : ('runtime, 'error) timer_policy;
  mutable generation : int;
  mutable demanded : bool;
  mutable state : ('runtime, 'error) timer_state;
  mutable queued : bool;
  on_start_failure :
    generation:int ->
    'error failure ->
    (unit, 'error) outcome;
}

type 'error run_error =
  | Runtime_mismatch
  | Cleanup_failures of 'error failure list
  | Callback_failure of 'error failure

type timer_action =
  | Start : ('runtime, 'error) timer * int -> timer_action
  | Stop :
      ('runtime, 'error) timer
      * int
      * (unit -> (unit, 'error) outcome)
      -> timer_action

type installed_timer =
  | Timer_installation :
      ('runtime, 'error) timer
      * int
      * (unit -> (unit, 'error) outcome)
      -> installed_timer

let checked_succ label value =
  if value = max_int then invalid_arg (label ^ " exhausted") else value + 1

let claim _t (f @ local) = f ()

let create () =
  {
    next_token = 0;
    hooks = Queue.create ();
    timer_hooks = Queue.create ();
    timers = Queue.create ();
    counts =
      {
        timer_claims = 0;
        callback_claims = 0;
        acknowledgements = 0;
        releases = 0;
      };
  }

let observe : type (a : value_or_null) error.
    t ->
    ?finish:(finish_reason -> (unit, error) outcome) ->
    (a delivery -> (unit, error) outcome) ->
    a observer =
 fun owner ?(finish = fun _ -> Success ()) callback ->
  {
    owner;
    lifecycle = Active;
    cursor = Never_delivered;
    callback = (fun delivery -> Obj.magic (callback delivery));
    finish = (fun reason -> Obj.magic (finish reason));
  }

let base = function
  | Never_delivered | Pending (_, Initialized _) | Running (_, Initialized _) ->
      None
  | Delivered value -> Some value
  | Pending (_, Changed (old_value, _))
  | Running (_, Changed (old_value, _)) ->
      Some old_value

let publish t observer value =
  if observer.owner != t then invalid_arg "selected_edges: observer owner";
  let outcome =
    claim t @@ stack_ (fun () ->
      match observer.lifecycle with
      | Finished _ -> ()
      | Active -> (
          match base observer.cursor with
          | Some old when old == value -> ()
          | previous ->
              let token =
                checked_succ "selected_edges observer token" t.next_token
              in
              let event =
                match previous with
                | None -> Initialized value
                | Some old -> Changed (old, value)
              in
              t.next_token <- token;
              observer.cursor <- Pending (token, event)))
  in
  outcome

let finish_observer_under_lane t observer reason =
  match observer.lifecycle with
  | Finished _ -> ()
  | Active ->
      observer.lifecycle <- Finished reason;
      observer.cursor <-
        (match base observer.cursor with
        | None -> Never_delivered
        | Some value -> Delivered value);
      Queue.add
        (Hook (fun () -> Obj.magic (observer.finish reason)))
        t.hooks

let finish_observer t observer reason =
  if observer.owner != t then invalid_arg "selected_edges: observer owner";
  claim t (fun () -> finish_observer_under_lane t observer reason)

let dispose t observer = finish_observer t observer Disposed
let invalidate t observer = finish_observer t observer Invalid_scope

let current delivery =
  let observer = delivery.observer in
  let outcome =
    claim observer.owner @@ stack_ (fun () ->
      if delivery.acknowledged then None
      else
        match observer.lifecycle, observer.cursor with
        | Active, (Pending (token, _) | Running (token, _))
          when token = delivery.token ->
            Some delivery.event
        | Active, _ | Finished _, _ -> None)
  in
  outcome

let acknowledge delivery =
  let observer = delivery.observer in
  let outcome =
    claim observer.owner @@ stack_ (fun () ->
      if delivery.acknowledged then false
      else
        match observer.lifecycle, observer.cursor with
        | Active, (Pending (token, event) | Running (token, event))
          when token = delivery.token ->
          delivery.acknowledged <- true;
          observer.cursor <-
            Delivered
              (match event with
              | Initialized value | Changed (_, value) -> value);
          observer.owner.counts.acknowledgements <-
            observer.owner.counts.acknowledgements + 1;
          true
        | Active, _ | Finished _, _ -> false)
  in
  outcome

let publish_sealed delivery publish =
  Fun.protect
    ~finally:(fun () -> ignore (acknowledge delivery : bool))
    (fun () -> publish delivery.event)

let create_timer_with_cleanup owner ~runtime ~policy ~on_start_failure =
  {
    owner;
    runtime;
    policy;
    generation = 0;
    demanded = false;
    state = Inactive;
    queued = false;
    on_start_failure;
  }

let create_timer owner ~runtime ~policy =
  create_timer_with_cleanup owner ~runtime ~policy
    ~on_start_failure:(fun ~generation:_ _ -> Success ())

let enqueue (timer : (_, _) timer) =
  if not timer.queued then (
    timer.queued <- true;
    Queue.add (Timer timer) timer.owner.timers)

let set_timer_demand_under_lane (timer : (_, _) timer) demanded =
  if timer.demanded <> demanded then (
    (match demanded, timer.state with
    | false, (Starting _ | Running _) ->
        timer.generation <-
          checked_succ "selected_edges timer generation" timer.generation
    | true, _ | false, Inactive -> ());
    timer.demanded <- demanded;
    match demanded, timer.state with
    | true, Inactive | false, (Starting _ | Running _) -> enqueue timer
    | true, (Starting _ | Running _) | false, Inactive -> ())

let set_timer_demand t (timer : (_, _) timer) demanded =
  if timer.owner != t then invalid_arg "selected_edges: timer owner";
  claim t (fun () -> set_timer_demand_under_lane timer demanded)

let activate_timer_registration t (timer : (_, _) timer) observer =
  if timer.owner != t || observer.owner != t then
    invalid_arg "selected_edges: registration owner";
  claim t @@ fun () ->
  match observer.lifecycle with
  | Finished _ -> ()
  | Active -> set_timer_demand_under_lane timer true

let abort_timer_registration t (timer : (_, _) timer) observer reason =
  if timer.owner != t || observer.owner != t then
    invalid_arg "selected_edges: registration owner";
  claim t @@ fun () ->
  finish_observer_under_lane t observer reason;
  set_timer_demand_under_lane timer false

let timer_generation (timer : (_, _) timer) = timer.generation

let timer_wake_with t ~runtime (timer : (_, _) timer) ~generation ~admit =
  if timer.owner != t then invalid_arg "selected_edges: timer owner";
  claim t @@ fun () ->
  if not (timer.policy.same_runtime runtime timer.runtime) then
    Error Runtime_mismatch
  else
    Ok
      (match timer.state with
      | Running (active, _)
        when active = generation
             && timer.generation = generation
             && timer.demanded ->
          admit ();
          true
      | Inactive | Starting _ | Running _ -> false)

let timer_wake t ~runtime timer ~generation =
  timer_wake_with t ~runtime timer ~generation ~admit:(fun () -> ())

let daemon_failed t (timer : (_, _) timer) ~generation =
  if timer.owner != t then invalid_arg "selected_edges: timer owner";
  claim t @@ fun () ->
  match timer.state with
  | Starting active when active = generation ->
      timer.state <- Inactive;
      if timer.demanded then enqueue timer
  | Running (active, _) when active = generation ->
      timer.state <- Inactive;
      if timer.demanded then enqueue timer
  | Inactive | Starting _ | Running _ -> ()

let queued_timers t = Queue.fold (fun rest timer -> timer :: rest) [] t.timers

let claim_timer_actions t =
  let outcome =
    claim t @@ stack_ (fun () ->
      let queued = List.rev (queued_timers t) in
      match queued with
      | [] -> Ok []
      | _ :: _ -> (
        Queue.clear t.timers;
        let actions = ref [] in
        List.iter
          (fun (Timer timer) ->
            if timer.queued then (
              timer.queued <- false;
              t.counts.timer_claims <- t.counts.timer_claims + 1;
              match timer.demanded, timer.state with
              | true, Inactive ->
                  let generation =
                    checked_succ "selected_edges timer generation"
                      timer.generation
                  in
                  timer.generation <- generation;
                  timer.state <- Starting generation;
                  actions := Start (timer, generation) :: !actions
              | false, Running (generation, stop) ->
                  actions := Stop (timer, generation, stop) :: !actions
              | false, Starting _ ->
                  (* Installation will observe the generation fence. *)
                  ()
              | true, (Starting _ | Running _) | false, Inactive -> ()))
          queued;
        Ok (List.rev !actions)))
  in
  outcome

let settle_start (timer : (_, _) timer) generation stop =
  claim timer.owner @@ fun () ->
  match timer.state with
  | Starting active
    when active = generation
         && timer.generation = generation
         && timer.demanded ->
      timer.state <- Running (generation, stop);
      true
  | Starting active when active = generation ->
      timer.state <- Inactive;
      Queue.add (Hook stop) timer.owner.timer_hooks;
      if timer.demanded then enqueue timer;
      false
  | Inactive | Starting _ | Running _ ->
      Queue.add (Hook stop) timer.owner.timer_hooks;
      false

let failed_start (timer : (_, _) timer) generation =
  claim timer.owner @@ fun () ->
  (match timer.state with
  | Starting active when active = generation -> timer.state <- Inactive
  | Inactive | Starting _ | Running _ -> ());
  if timer.demanded then enqueue timer

let settle_stop (timer : (_, _) timer) generation =
  claim timer.owner @@ fun () ->
  match timer.state with
  | Running (active, _) when active = generation ->
      timer.state <- Inactive;
      if timer.demanded || timer.generation <> generation then enqueue timer
  | Inactive | Starting _ | Running _ -> ()

let failed_stop (timer : (_, _) timer) =
  claim timer.owner (fun () -> enqueue timer)

let run_actions actions =
  if actions = [] then []
  else
  let failures = ref [] in
  let installed = ref [] in
  let start_failed = ref false in
  let record failure = failures := failure :: !failures in
  List.iter
    (function
      | Start (timer, generation) -> (
          match timer.policy.start timer.runtime ~generation with
          | Success stop ->
              if settle_start timer generation stop then
                installed :=
                  Timer_installation (timer, generation, stop) :: !installed
          | Failure failure ->
              start_failed := true;
              failed_start timer generation;
              record (Obj.magic failure);
              (match timer.on_start_failure ~generation failure with
              | Success () -> ()
              | Failure cleanup_failure ->
                  record (Obj.magic cleanup_failure))
          | exception exn ->
              start_failed := true;
              failed_start timer generation;
              ignore
                (timer.on_start_failure ~generation (Defect exn)
                  : (unit, _) outcome);
              raise exn)
      | Stop (timer, generation, stop) -> (
          match stop () with
          | Success () -> settle_stop timer generation
          | Failure failure ->
              failed_stop timer;
              record (Obj.magic failure)
          | exception exn ->
              failed_stop timer;
              raise exn))
    actions;
  if !start_failed then
    List.iter
      (fun (Timer_installation (timer, generation, stop)) ->
        match stop () with
        | Success () -> settle_stop timer generation
        | Failure failure ->
            failed_stop timer;
            record (Obj.magic failure)
        | exception exn ->
            failed_stop timer;
            raise exn)
      (List.rev !installed);
  List.rev !failures

let claim_hooks t =
  claim t @@ fun () ->
  let hooks = Queue.fold (fun rest hook -> hook :: rest) [] t.hooks in
  Queue.clear t.hooks;
  List.rev hooks

let run_hooks hooks =
  let failures = ref [] in
  List.iter
    (fun (Hook hook) ->
      match hook () with
      | Success () -> ()
      | Failure failure -> failures := Obj.magic failure :: !failures)
    hooks;
  List.rev !failures

let settle_delivery observer token event delivered =
  let outcome =
    claim observer.owner @@ stack_ (fun () ->
      match observer.lifecycle, observer.cursor with
      | Active, Running (active, _) when active = token ->
          if delivered then (
            observer.cursor <-
              Delivered
                (match event with
                | Initialized value | Changed (_, value) -> value);
            observer.owner.counts.acknowledgements <-
              observer.owner.counts.acknowledgements + 1)
          else (
            observer.cursor <- Pending (token, event);
            observer.owner.counts.releases <- observer.owner.counts.releases + 1)
      | Active, _ | Finished _, _ -> ())
  in
  outcome

let rec deliver t = function
  | [] -> Ok ()
  | Observer observer :: rest -> (
      (* claim_delivery inlined: the Claim existential and Some wrappers cost
         six words per delivery for a single caller. *)
      if observer.owner != t then
        invalid_arg "selected_edges: observer plan owner";
      match observer.lifecycle, observer.cursor with
      | Active, Pending (token, event) -> (
          observer.cursor <- Running (token, event);
          t.counts.callback_claims <- t.counts.callback_claims + 1;
          let delivery =
            { observer; token; event; acknowledged = false }
          in
          match observer.callback delivery with
          | Success () ->
              settle_delivery observer token event true;
              deliver t rest
          | Failure (Typed_failure _ as failure) ->
              settle_delivery observer token event true;
              Error (Callback_failure (Obj.magic failure))
          | Failure (Defect exn | Interrupted exn) ->
              settle_delivery observer token event false;
              raise exn
          | exception exn ->
              settle_delivery observer token event false;
              raise exn)
      | Active, (Never_delivered | Delivered _ | Running _) | Finished _, _ ->
          deliver t rest)

let drain_cleanup_failures t =
  if Queue.is_empty t.timer_hooks && Queue.is_empty t.hooks then []
  else
  let timer_hooks =
    claim t @@ fun () ->
    let hooks =
      Queue.fold (fun rest hook -> hook :: rest) [] t.timer_hooks
    in
    Queue.clear t.timer_hooks;
    List.rev hooks
  in
  let timer_failures = run_hooks timer_hooks in
  let hook_failures = run_hooks (claim_hooks t) in
  timer_failures @ hook_failures

let drain_cleanup t =
  match drain_cleanup_failures t with
  | [] -> Ok ()
  | failures -> Error (Cleanup_failures failures)

let rec plan_is_idle t = function
  | [] -> true
  | Observer observer :: rest ->
      if observer.owner != t then
        invalid_arg "selected_edges: observer plan owner";
      (match observer.lifecycle, observer.cursor with
      | Active, Pending _ -> false
      | Active, (Never_delivered | Delivered _ | Running _) | Finished _, _ ->
          plan_is_idle t rest)

let is_quiescent t plan =
  Queue.is_empty t.timers
  && Queue.is_empty t.timer_hooks
  && Queue.is_empty t.hooks
  && plan_is_idle t plan

let run t ~plan =
  if is_quiescent t plan then Ok ()
  else if Queue.is_empty t.timers then (
    (* No timers are queued, so there are no timer actions to claim; only
       cleanup hooks and the plan delivery remain. *)
    let failures = drain_cleanup_failures t in
    if failures <> [] then Error (Cleanup_failures failures)
    else deliver t plan)
  else
    match claim_timer_actions t with
    | Error (Runtime_mismatch | Cleanup_failures _ | Callback_failure _) ->
        assert false
    | Ok actions ->
        let action_failures = run_actions actions in
        let failures = action_failures @ drain_cleanup_failures t in
        if failures <> [] then Error (Cleanup_failures failures)
        else deliver t plan

let stats t : stats =
  claim t @@ fun () ->
  ({
     timer_claims = t.counts.timer_claims;
     callback_claims = t.counts.callback_claims;
     acknowledgements = t.counts.acknowledgements;
     releases = t.counts.releases;
   }
    : stats)

let queued_timer_count t = claim t (fun () -> Queue.length t.timers)
