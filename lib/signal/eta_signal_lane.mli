(** Serialized graph-lane acquisition for Eta_signal internals. *)

type t
type access

type hooks = {
  note_waiter_enqueued : unit -> unit;
  note_waiter_compaction : unit -> unit;
}

val create : unit -> t

val enter : hooks:hooks -> Eta.Runtime_contract.t -> t -> access
val leave : t -> access -> unit

val can_reenter :
  lane_depth:int -> owner_fiber_id:int option -> current_fiber_id:int -> bool

val with_sync :
  leaf_name:string ->
  depth_local:int Eta.Runtime_contract.local ->
  ensure_context:(unit -> unit) ->
  hooks:hooks ->
  after_acquired:(unit -> (unit, 'err) Eta.Effect.t) ->
  t ->
  (unit -> 'a) ->
  ('a, 'err) Eta.Effect.t

val waiting_count : t -> int
val cancelled_count : t -> int

val should_compact_cancelled :
  retained_cancelled:int -> queue_length:int -> bool
