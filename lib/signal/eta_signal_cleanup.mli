(** Cleanup hook execution for Eta_signal internals. *)

type hook = unit -> unit

val run_hooks : hook list -> (unit, 'error) Eta.Effect.t
val run_as_finalizers : hook list -> (unit, 'error) Eta.Effect.t
val run_pending_as_finalizers : hook list ref -> (unit, 'error) Eta.Effect.t
val fail_with_pending : hook list ref -> ('a, 'error) Eta.Effect.t -> ('a, 'error) Eta.Effect.t
val run_pending : hook list ref -> (unit, 'error) Eta.Effect.t
val pending : hook list ref -> bool
