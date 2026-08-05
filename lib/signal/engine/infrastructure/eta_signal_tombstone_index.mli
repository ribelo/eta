(** Bounded tombstone-index instrumentation. *)

type counters

type counter_snapshot = {
  slot_writes : int;
  evictions : int;
  iteration_visits : int;
  duplicate_scan_steps : int;
}

val create_counters : unit -> counters
val reset_counters : counters -> unit
val disable_counters : counters -> unit
val counter_snapshot : counters -> counter_snapshot
val note_slot_write : counters -> unit
val note_eviction : counters -> unit
val note_iteration_visit : counters -> unit
val note_duplicate_scan_step : counters -> unit

val capacity : int
(** Fixed slot count. *)

type 'a t
(** Bounded invalid-node tombstone retention as a graph-allocated circular
    array. Node lifetimes are one-way, so a node contributes at most one
    tombstone; insertion performs no duplicate scan. *)

val create : unit -> 'a t

val insert : counters -> 'a -> 'a t -> unit
(** One slot write per insertion, replacing the oldest entry when the ring is
    full. *)

val length : 'a t -> int

val iter : counters -> f:('a -> unit) -> 'a t -> unit
(** Newest first, at most [capacity] entries. *)

val map : counters -> f:('a -> 'b) -> 'a t -> 'b list
(** Newest first. *)
