(** Core graph identity, ID allocation, and counters for Eta_signal internals. *)

type t

type counter =
  | Callback_delivery_count
  | Recompute_count
  | Dynamic_scope_invalidations
  | Nodes_became_necessary
  | Nodes_became_unnecessary

val create : unit -> t

val lane : t -> Eta_signal_lane.t
val owner_domain : t -> Domain.id

val next_signal_id :
  t -> (Eta_signal_id.signal, Eta_signal_error.graph_error) result

val next_var_id : t -> (Eta_signal_id.var, Eta_signal_error.graph_error) result

val next_observer_id :
  t -> (Eta_signal_id.observer, Eta_signal_error.graph_error) result

val next_scope_id :
  t -> (Eta_signal_id.scope, Eta_signal_error.graph_error) result

val set_next_node_id : t -> int -> unit
val set_next_scope_id : t -> int -> unit

val counter : t -> counter -> int
val set_counter : t -> counter -> int -> unit
val bump_counter : t -> counter -> unit

val update_necessary_ids : t -> (Eta_signal_id.signal, unit) Hashtbl.t -> unit
