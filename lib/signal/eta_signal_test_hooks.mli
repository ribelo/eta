(** Mutable hook state for Eta_signal private tests. *)

type hook =
  | After_observer_delivery_claim
  | After_observer_activation_before_return
  | After_graph_lane_acquired

type action = { run : 'err. unit -> (unit, 'err) Eta.Effect.t }

type t

val create : unit -> t
val with_hook : t -> hook -> action -> (unit -> 'a) -> 'a
val clear : t -> unit
val run : t -> hook -> (unit, 'err) Eta.Effect.t
val set_timer_runtime_mismatch_hook : t -> (unit -> unit) -> unit
val run_timer_runtime_mismatch_hook : t -> unit
