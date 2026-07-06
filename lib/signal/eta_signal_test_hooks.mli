(** Mutable hook state for Eta_signal private tests. *)

type hook =
  | After_observer_delivery_claim
  | After_observer_activation_before_return
  | After_graph_lane_acquired

type stats_count =
  | Stats_total_node_count
  | Stats_necessary_node_count
  | Stats_dead_node_count
  | Stats_lane_cancelled_waiter_count

type action = { run : 'err. unit -> (unit, 'err) Eta.Effect.t }

type t

val create : unit -> t
val with_hook : t -> hook -> action -> (unit -> 'a) -> 'a
val clear : t -> unit
val run : t -> hook -> (unit, 'err) Eta.Effect.t
val set_stats_count_override : t -> stats_count -> int option -> unit
val stats_count_override : t -> stats_count -> int option
val set_timer_runtime_mismatch_hook : t -> (unit -> unit) -> unit
val run_timer_runtime_mismatch_hook : t -> unit
