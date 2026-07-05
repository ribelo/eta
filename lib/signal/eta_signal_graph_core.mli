(** Core graph identity, ID allocation, and counters for Eta_signal internals. *)

type t
type lane_access

type lane_hooks

val lane_hooks :
  note_waiter_enqueued:(unit -> unit) ->
  note_waiter_compaction:(unit -> unit) ->
  lane_hooks

type counter =
  | Callback_delivery_count
  | Recompute_count
  | Dynamic_scope_invalidations
  | Nodes_became_necessary
  | Nodes_became_unnecessary

val create : unit -> t

val context_error_message : string
val ensure_context : t -> unit

val with_lane_access :
  t ->
  leaf_name:string ->
  depth_local:int Eta.Runtime_contract.local ->
  hooks:lane_hooks ->
  after_acquired:(unit -> (unit, 'error) Eta.Effect.t) ->
  (lane_access -> 'a) ->
  ('a, 'error) Eta.Effect.t

val lane_waiting_count : t -> int
val lane_cancelled_count : t -> int

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
val bump_counter : t -> lane_access -> counter -> unit

val update_necessary_ids :
  t -> lane_access -> (Eta_signal_id.signal, unit) Hashtbl.t -> unit
