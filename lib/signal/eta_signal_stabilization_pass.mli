(** Pure stabilization pass orchestration for Eta_signal internals. *)

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
(** Callback surface for graph-specific work performed in a pure stabilization
    pass. The module owns callback ordering, phase transitions, and rollback
    cleanup; callers provide only graph operations. *)

val run :
  'error Eta_signal_stabilization.t ->
  ('pending, 'observer, 'event, 'hook, 'error) t ->
  ('hook, 'event, 'error) result
