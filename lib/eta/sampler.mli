(** Trace sampling policies.

    A sampler decides whether a new span should be recorded. It is evaluated
    when a span starts; the decision is not revisited for that span. *)

type t

val always_on : t
(** Record every span. *)

val always_off : t
(** Drop every span. *)

val ratio : float -> t
(** Sample a fixed ratio of traces. The ratio is clipped to [[0.0, 1.0]].
    Decision is deterministic per trace ID. *)

val parent_based : ?root:t -> unit -> t
(** Honor the parent's sampled flag when one exists; use [root] for root spans.
    Defaults to [always_on] for root spans. *)

val sample :
  t ->
  trace_id:string ->
  name:string ->
  attrs:(string * string) list ->
  parent:bool ->
  bool
(** Evaluate the policy for a span with the given identifiers. *)
