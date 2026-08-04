(** Cleanup hook execution for Eta_signal internals. *)

type hook = unit -> unit

type counters

type counter_snapshot = {
  resource_registrations : int;
  terminal_transitions : int;
  hook_attempts : int;
  hook_completions : int;
  duplicate_transition_rejections : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_resource_registration : counters -> unit
val note_terminal_transition : counters -> unit
val note_hook_attempt : counters -> unit
val note_hook_completion : counters -> unit
val note_duplicate_transition_rejection : counters -> unit

type disposition =
  | Committed
  | Discarded

type ledger
type resource

val create_ledger : counters -> ledger
val register : ledger -> hook -> resource

val transition :
  ledger ->
  resource ->
  disposition ->
  (hook option, [ `Already_terminal ]) result

val pending_resources : ledger -> int

val run_hooks : hook list -> (unit, 'error) Eta.Effect.t
val run_as_finalizers : hook list -> (unit, 'error) Eta.Effect.t
val run_pending_as_finalizers : hook list ref -> (unit, 'error) Eta.Effect.t
val fail_with_pending : hook list ref -> ('a, 'error) Eta.Effect.t -> ('a, 'error) Eta.Effect.t
val run_pending : hook list ref -> (unit, 'error) Eta.Effect.t
val pending : hook list ref -> bool
