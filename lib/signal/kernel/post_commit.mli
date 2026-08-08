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
type 'a update = Initialized of 'a | Changed of 'a * 'a
type finish_reason = Disposed | Invalid_scope

type 'error run_error =
  | Runtime_mismatch
  | Cleanup_failures of 'error failure list
  | Callback_failure of 'error failure

type t
type 'a observer
type 'a delivery
type packed_observer = Observer : 'a observer -> packed_observer
type ('runtime, 'error) timer

type ('runtime, 'error) timer_policy = {
  same_runtime : 'runtime -> 'runtime -> bool;
  start :
    'runtime ->
    generation:int ->
    ((unit -> (unit, 'error) outcome), 'error) outcome;
}

val create : unit -> t

val observe :
  t ->
  ?finish:(finish_reason -> (unit, 'error) outcome) ->
  ('a delivery -> (unit, 'error) outcome) ->
  'a observer

val publish : t -> 'a observer -> 'a -> unit
val dispose : t -> 'a observer -> unit
val invalidate : t -> 'a observer -> unit
val current : 'a delivery -> 'a update option

val create_timer_with_cleanup :
  t ->
  runtime:'runtime ->
  policy:('runtime, 'error) timer_policy ->
  on_start_failure:(generation:int -> 'error failure -> (unit, 'error) outcome) ->
  ('runtime, 'error) timer

val set_timer_demand : t -> ('runtime, 'error) timer -> bool -> unit

val activate_timer_registration :
  t -> ('runtime, 'error) timer -> 'a observer -> unit

val abort_timer_registration :
  t -> ('runtime, 'error) timer -> 'a observer -> finish_reason -> unit

val timer_generation : ('runtime, 'error) timer -> int

val timer_wake_with :
  t ->
  runtime:'runtime ->
  ('runtime, 'error) timer ->
  generation:int ->
  admit:(unit -> unit) ->
  (bool, 'error run_error) result

val daemon_failed : t -> ('runtime, 'error) timer -> generation:int -> unit
val drain_cleanup : t -> (unit, 'error run_error) result
val run : t -> plan:packed_observer list -> (unit, 'error run_error) result
val queued_timer_count : t -> int
