(** Effectful timer daemon adapter for Eta_signal internals.

    Timer_policy owns pure timer state transitions. This module owns the
    effectful daemon loop: cancellation normalization, clock/sleep scheduling,
    due advancement, and batched update ordering. Graph-specific mutation stays
    behind callbacks. *)

type continue =
  [ `Continue
  | `Stop
  ]

type advance =
  [ `Advanced
  | `Stale
  | `Stop
  ]

type 'error callbacks = {
  read_next_due :
    generation:int -> fallback:int -> (int option, 'error) Eta.Effect.t;
  advance_next_due :
    generation:int ->
    expected:int ->
    next_due_ms:int ->
    (advance, 'error) Eta.Effect.t;
  after_update_state :
    generation:int -> (continue, 'error) Eta.Effect.t;
  finish_saturated : generation:int -> (unit, 'error) Eta.Effect.t;
  construct_update :
    generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
  after_due_read_before_commit : unit -> (unit, 'error) Eta.Effect.t;
  after_update_constructed_before_run : unit -> (unit, 'error) Eta.Effect.t;
}

type 'error start_callbacks = {
  begin_start : generation:int -> (continue, 'error) Eta.Effect.t;
  set_next_due :
    generation:int -> next_due_ms:int -> (continue, 'error) Eta.Effect.t;
  after_start_update :
    generation:int -> (continue, 'error) Eta.Effect.t;
  construct_start_update :
    generation:int -> missed:int -> (unit, 'error) Eta.Effect.t;
  install_cancel :
    generation:int ->
    cancel:(unit -> unit) ->
    (continue, 'error) Eta.Effect.t;
  cleanup_after_exit :
    generation:int ->
    (unit, 'error) Eta.Exit.t ->
    (unit, 'error) Eta.Effect.t;
  cleanup_failed_start :
    generation:int ->
    (unit, 'error) Eta.Exit.t ->
    (unit, 'error) Eta.Effect.t;
}

val run_cancellable :
  install_cancel:
    (cancel:(unit -> unit) -> (continue, 'error) Eta.Effect.t) ->
  loop:(unit, 'error) Eta.Effect.t ->
  (unit, 'error) Eta.Effect.t

val run_loop :
  'error callbacks ->
  generation:int ->
  interval_ms:int ->
  next_due_ms:int ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  (unit, 'error) Eta.Effect.t

val start :
  'error start_callbacks ->
  'error callbacks ->
  generation:int ->
  interval_ms:int ->
  update_on_start:bool ->
  catch_up_policy:Eta_signal_timer_policy.catch_up_policy ->
  (unit, 'error) Eta.Effect.t
