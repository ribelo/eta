type ('hook, 'event, 'error) result =
  | Pure_ok of
      'hook list
      * 'event list
      * Eta_signal_stabilization.delivering Eta_signal_stabilization.token
  | Pure_graph_error of 'hook list * 'error
  | Pure_defect of 'hook list * exn * Printexc.raw_backtrace

type ('pending, 'observer, 'event, 'hook, 'error) t = {
  reentrant_error : 'error;
  advance_generation : unit -> unit;
  begin_staging : unit -> unit;
  drain_pending : unit -> 'pending list;
  release_pending_marks : 'pending list -> unit;
  active_observers : unit -> 'observer list;
  stage_pending : 'pending list -> unit;
  plan_staged_binds : 'observer list -> unit;
  sort_delivery_observers : 'observer list -> 'observer list;
  collect_events : 'observer list -> 'event list;
  commit_staging : unit -> 'hook list;
  mark_events_pending : 'event list -> unit;
  update_necessity : unit -> unit;
  clear_timer_refresh : unit -> unit;
  rollback_staging : unit -> 'hook list;
  mark_observers_failed_without_current : 'observer list -> unit;
  requeue_pending : 'pending list -> unit;
  classify_graph_error : exn -> 'error option;
}

type ('event, 'error) delivery = {
  run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
  run_events : 'event list -> (unit, 'error) Eta.Effect.t;
  mark_complete : unit -> (unit, 'error) Eta.Effect.t;
  finish : unit -> (unit, 'error) Eta.Effect.t;
}

let rollback state pure_token ops observers pending =
  let hooks = ops.rollback_staging () in
  ops.mark_observers_failed_without_current observers;
  ops.requeue_pending pending;
  ops.clear_timer_refresh ();
  ignore
    (Eta_signal_stabilization.rollback_to_idle state pure_token
      : Eta_signal_stabilization.idle Eta_signal_stabilization.token);
  hooks

let run state ops =
  match Eta_signal_stabilization.begin_pure state with
  | Error `Reentrant_stabilization ->
      Pure_graph_error ([], ops.reentrant_error)
  | Ok pure_token ->
      ops.advance_generation ();
      ops.begin_staging ();
      let pending = ops.drain_pending () in
      ops.release_pending_marks pending;
      let observers = ops.active_observers () in
      try
        ops.stage_pending pending;
        ops.plan_staged_binds observers;
        let delivery_observers = ops.sort_delivery_observers observers in
        let events = ops.collect_events delivery_observers in
        let hooks = ops.commit_staging () in
        ops.mark_events_pending events;
        ops.update_necessity ();
        ops.clear_timer_refresh ();
        let delivering_token =
          Eta_signal_stabilization.commit_to_delivering state pure_token
        in
        Pure_ok (hooks, events, delivering_token)
      with exn -> (
        let backtrace = Printexc.get_raw_backtrace () in
        let hooks = rollback state pure_token ops observers pending in
        match ops.classify_graph_error exn with
        | Some err -> Pure_graph_error (hooks, err)
        | None -> Pure_defect (hooks, exn, backtrace))

let finish_delivery ops =
  let open Eta in
  ops.run_pending_cleanup ()
  |> Effect.on_exit (fun _exit -> ops.finish ())

let deliver ops events =
  let open Eta in
  (ops.run_pending_cleanup ()
  |> Effect.bind (fun () -> ops.run_events events)
  |> Effect.bind ops.mark_complete)
  |> Effect.on_exit (fun _exit -> finish_delivery ops)
