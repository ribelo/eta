(** Worker-domain offload for CPU-bound or non-Eio workloads. *)

type worker_die = {
  kind : string;
  message : string;
  backtrace : string option;
}
(** Diagnostic returned when a worker-domain callback raises before producing
    its declared result. This stays smaller than {!Cause.t} because raw OCaml
    causes do not cross the island boundary. *)

type ('a, 'e) settled =
  | Ok of 'a
  | Error of 'e
  | Worker_died of worker_die
(** Per-item result for {!all_settled}. [Ok] and [Error] are the callback's
    own result channel; [Worker_died] is an unchecked worker crash. *)

type pool
(** Reusable heartbeat-backed island pool. Create it once, pass it to the
    runtime or to a batch override, and shut it down at program exit. Pool
    creation is intentionally not hidden because it is comparatively expensive
    and because missing configuration must fail loudly. *)

val run :
  ?name:string ->
  ('input -> 'output) ->
  'input ->
  ('output, 'err) Effect.t
(** Run one callback through the runtime's configured island pool.

    Anything accepted by [run] can also be expressed with {!Effect.sync}; the
    reverse is deliberately false because [run] crosses a worker-domain
    boundary. The runtime must be configured with an island pool; Eta never
    silently falls back to same-domain execution. No timeout, cancellation,
    preemption, streaming/online queueing, worker-safe AST, or
    Resource/Supervisor/Eta_stream/OTel behavior is implied by this primitive.
    Upstream OCaml does not enforce cross-domain payload safety here; callers
    must keep callbacks bounded and avoid sharing mutable state unsafely. *)

val map :
  ?name:string ->
  ?pool:pool ->
  f:('input -> 'output) ->
  'input list ->
  ('output list, 'err) Effect.t
(** Run a finite batch of callbacks and return results in input order.
    Worker crashes fail the outer eff as defects.

    Running callbacks are not preempted. Parent cancellation or an Eta timeout
    can stop waiting for the batch, but cannot safely reclaim worker domains
    already executing user code. Use only bounded callbacks that return on
    their own. *)

val map_result :
  ?name:string ->
  ?pool:pool ->
  f:('input -> ('output, 'error) result) ->
  'input list ->
  (('output, 'error) result list, 'err) Effect.t
(** Like {!map}, but the callback returns a typed per-item [result].
    Callback [Error _] values are returned in place; worker crashes still fail
    the outer eff as defects. The same non-preemptive callback contract as
    {!map} applies. *)

val all_settled :
  ?name:string ->
  ?pool:pool ->
  f:('input -> ('output, 'error) result) ->
  'input list ->
  (('output, 'error) settled list, 'err) Effect.t
(** Run a finite batch and return one settled outcome per input, preserving
    input order. Worker crashes are represented as [Worker_died] values instead
    of aborting siblings. The same non-preemptive callback contract as {!map}
    applies. *)

module Pool : sig
  type t = pool

  val create : ?domains:int -> unit -> t
  (** Create a reusable island pool. [domains] defaults to [2].
      @raise Invalid_argument if [domains <= 0]. *)

  val shutdown : t -> unit
  (** Stop the pool. Calling it more than once is harmless; submitting work to
      a stopped pool raises [Invalid_argument]. *)
end
