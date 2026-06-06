(** Eta_par: native fork-join data parallelism.

    Eta_par offers fork-join data parallelism on multiple cores.
    The public surface is deliberately small: pools, [run], [join], and a
    handful of array and iterator combinators.

    {1 Quick start}

    {[
      let _ = Eta_par.run (fun () ->
        let a, b = Eta_par.join
            (fun () -> compute_left ())
            (fun () -> compute_right ()) in
        a + b)
    ]}

    All combinators block the calling task until the spawned work is
    done.  They never raise from the runtime itself; user exceptions are
    propagated. *)

(** {1 Pools} *)

module Pool : sig
  (** A long-lived pool of worker domains. *)
  type t

  val create :
    ?n_workers:int ->
    ?heartbeat_interval_ns:int ->
    ?par_threshold:int ->
    unit ->
    t
  (** Create a pool with [n_workers] workers (default:
      [Domain.recommended_domain_count ()]).  Worker 0 is reserved
      for the caller of {!run}; workers 1..n-1 each spawn a domain
      that idles on a condvar waiting for work.  A separate domain
      ticks every worker's heartbeat flag round-robin every
      [heartbeat_interval_ns] nanoseconds (default 100 µs).
      [par_threshold] sets the default leaf size for recursive parallel
      combinators run on this pool when they do not receive [?chunk]
      directly.  The pool stays alive until {!shutdown} is called. *)

  val run : t -> (unit -> 'a) -> 'a
  (** [run pool f] runs [f] as the root task on the calling thread.  The
      caller participates as worker 0 for the duration of the call.

      Calling [run] concurrently on the same pool is not supported. *)

  val run_on_worker : t -> (unit -> 'a) -> 'a
  (** [run_on_worker pool f] schedules [f] on a long-lived worker domain and
      blocks the caller until it returns.  If the pool has no background
      workers, [f] runs inline.

      Jobs are ordinary CPU callbacks: the pool does not inject cancellation
      checks, timeouts, or preemption.  A job that never returns keeps its worker
      occupied and keeps the caller blocked.

      This is the entry point for typed offload wrappers such as
      [Island.run].  Use {!run} for explicit fork-join roots where the
      caller should participate as worker 0. *)

  val run_many_on_workers : t -> (unit -> 'a) list -> 'a list
  (** [run_many_on_workers pool jobs] schedules all [jobs] on long-lived
      worker domains and returns results in input order after every job
      finishes.  If any job raises, all jobs still finish and the first
      exception in input order is re-raised.

      The same non-preemptive job contract as {!run_on_worker} applies to every
      item in the batch. *)

  val shutdown : t -> unit
  (** Signal all worker domains to exit and join them.  Calling [run]
      after shutdown is undefined. *)

  val with_pool :
    ?n_workers:int ->
    ?heartbeat_interval_ns:int ->
    ?par_threshold:int ->
    (t -> 'a) ->
    'a
  (** [with_pool ?n_workers f] = [create ?n_workers (), f, shutdown]. *)
end

(** {1 Top-level runner} *)

val run :
  ?n_workers:int ->
  ?heartbeat_interval_ns:int ->
  ?par_threshold:int ->
  (unit -> 'a) ->
  'a
(** Convenience: create a pool, run [f], shut down.  Use {!Pool.run} if
    you want to reuse the pool across multiple top-level calls. *)

(** {1 Fork-join} *)

val join : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
(** [join f g] runs [f] and [g] potentially in parallel and returns
    both results.

    Must be called from inside a task running on a pool worker (i.e.,
    transitively from {!run} or {!Pool.run}).

    The runtime may run either branch inline or on another worker. Exceptions
    raised by either branch propagate to the caller, with the other branch's
    work run to completion before [join] returns or raises. *)

val join3 :
  (unit -> 'a) -> (unit -> 'b) -> (unit -> 'c) -> 'a * 'b * 'c
(** Three-way fork-join. *)

(** {1 Parallel iteration} *)

val par_for :
  ?chunk:int -> start:int -> stop:int -> (int -> unit) -> unit
(** [par_for ?chunk ~start ~stop f] applies [f] to every integer in
    [[start, stop)] in parallel.  The range is recursively halved until
    each leaf is at most [chunk] integers wide; below that it runs
    serially.  Without [?chunk], the default comes from the current pool's
    [par_threshold].  Pass a smaller [chunk] for kernels with heavy
    per-iteration work and few iterations (e.g., [par_for ~chunk:1] over
    rows of a matmul). *)

val par_iter : ?chunk:int -> 'a array -> ('a -> unit) -> unit
(** [par_iter arr f] applies [f] to every element of [arr] in parallel. *)

val par_iteri : ?chunk:int -> 'a array -> (int -> 'a -> unit) -> unit
(** Like {!par_iter} but [f] also receives the index. *)

(** {1 Parallel map / reduce} *)

val par_map : ?chunk:int -> 'a array -> ('a -> 'b) -> 'b array
(** [par_map arr f] returns an array containing [f x] for each [x] in
    [arr], with elements computed in parallel.  Order is preserved. *)

val par_mapi : ?chunk:int -> 'a array -> (int -> 'a -> 'b) -> 'b array
(** Like {!par_map} but [f] receives the index. *)

val par_reduce :
  ?chunk:int ->
  'a array ->
  init:'b ->
  map:('a -> 'b) ->
  combine:('b -> 'b -> 'b) ->
  'b
(** [par_reduce arr ~init ~map ~combine] computes
    [combine (map arr.(0)) (combine ... init)] in parallel using a
    binary tree.  [combine] must be associative; [init] must be the
    left identity for [combine] (i.e., [combine init x = x]). *)

(** {1 Parallel sort} *)

val par_sort : 'a array -> ('a -> 'a -> int) -> unit
(** In-place parallel quicksort with three-way (Dutch national flag)
    partitioning.  The comparator must define a total order.  Inputs
    with many duplicate keys (in particular all-equal arrays) collapse
    cleanly without the O(N) recursion of plain Lomuto. *)

(** {1 Lazy parallel iterators}

    Lazy iterator chains layered on top of {!join}.  Construct
    with {!Iter.of_array} / {!Iter.of_range}, chain adapters lazily,
    then end with a consumer like {!Iter.reduce} or
    {!Iter.collect_array}.

    {[
      Eta_par.run @@ fun () ->
        arr
        |> Eta_par.Iter.of_array
        |> Eta_par.Iter.map (fun x -> x * x)
        |> Eta_par.Iter.filter (fun x -> x mod 3 = 0)
        |> Eta_par.Iter.reduce ~init:0 ~combine:(+)
    ]}
*)
module Iter : sig
  type 'a t

  val of_array : ?chunk:int -> 'a array -> 'a t
  val of_array_sub : ?chunk:int -> 'a array -> start:int -> stop:int -> 'a t
  val of_range : ?chunk:int -> start:int -> stop:int -> unit -> int t

  val map : ('a -> 'b) -> 'a t -> 'b t
  val mapi : (int -> 'a -> 'b) -> 'a t -> 'b t
  val filter : ('a -> bool) -> 'a t -> 'a t

  val for_each : ('a -> unit) -> 'a t -> unit
  val iter : ('a -> unit) -> 'a t -> unit

  val reduce : init:'a -> combine:('a -> 'a -> 'a) -> 'a t -> 'a
  val fold :
    init:'b ->
    step:('b -> 'a -> 'b) ->
    combine:('b -> 'b -> 'b) ->
    'a t ->
    'b

  val sum : int t -> int
  val count : 'a t -> int
  val min : 'a t -> 'a option
  val max : 'a t -> 'a option
  val min_with : cmp:('a -> 'a -> int) -> 'a t -> 'a option
  val max_with : cmp:('a -> 'a -> int) -> 'a t -> 'a option

  val collect_array : 'a t -> 'a array

  val find_any : ('a -> bool) -> 'a t -> 'a option
  val any : ('a -> bool) -> 'a t -> bool
  val all : ('a -> bool) -> 'a t -> bool
end

(** {1 Worker-domain islands} *)

module Island : sig
  (** Worker-domain offload for CPU-bound or noncooperative workloads.

      Islands are explicit native resources. Create a pool in this module and
      pass it to the island operations, or bind it once with {!Make}. The root
      Eta runtime does not carry an ambient island pool. *)

  type worker_die = {
    kind : string;
    message : string;
    backtrace : string option;
  }
  (** Diagnostic returned when a worker-domain callback raises before producing
      its declared result. *)

  type ('a, 'e) settled =
    | Ok of 'a
    | Error of 'e
    | Worker_died of worker_die
  (** Per-item result for {!all_settled}. [Ok] and [Error] are the callback's
      own result channel; [Worker_died] is an unchecked worker crash. *)

  type pool
  (** Reusable heartbeat-backed island pool. Create it once and shut it down at
      program exit. Pool creation is intentionally explicit because it is
      comparatively expensive and because same-domain fallback would hide a
      native boundary. *)

  val run :
    ?name:string ->
    pool:pool ->
    ('input -> 'output) ->
    'input ->
    ('output, 'err) Eta.Effect.t
  (** Run one callback through [pool].

      Anything accepted by [run] can also be expressed with
      {!Eta.Effect.sync}; the reverse is deliberately false because [run]
      crosses a worker-domain boundary. No timeout, cancellation, preemption,
      streaming/online queueing, worker-safe AST, or OTel behavior is implied by
      this primitive. Upstream OCaml does not enforce cross-domain payload
      safety here; callers must keep callbacks bounded and avoid sharing mutable
      state unsafely. *)

  val map :
    ?name:string ->
    pool:pool ->
    f:('input -> 'output) ->
    'input list ->
    ('output list, 'err) Eta.Effect.t
  (** Run a finite batch of callbacks and return results in input order.
      Worker crashes fail the outer effect as defects.

      Running callbacks are not preempted. Parent cancellation or an Eta timeout
      can stop waiting for the batch, but cannot safely reclaim worker domains
      already executing user code. Use only bounded callbacks that return on
      their own. *)

  val map_result :
    ?name:string ->
    pool:pool ->
    f:('input -> ('output, 'error) result) ->
    'input list ->
    (('output, 'error) result list, 'err) Eta.Effect.t
  (** Like {!map}, but the callback returns a typed per-item [result].
      Callback [Error _] values are returned in place; worker crashes still fail
      the outer effect as defects. *)

  val all_settled :
    ?name:string ->
    pool:pool ->
    f:('input -> ('output, 'error) result) ->
    'input list ->
    (('output, 'error) settled list, 'err) Eta.Effect.t
  (** Run a finite batch and return one settled outcome per input, preserving
      input order. Worker crashes are represented as [Worker_died] values
      instead of aborting siblings. *)

  module Pool : sig
    type t = pool

    val create : ?domains:int -> unit -> t
    (** Create a reusable island pool. [domains] defaults to [2].
        @raise Invalid_argument if [domains <= 0]. *)

    val shutdown : t -> unit
    (** Stop the pool. Calling it more than once is harmless; submitting work
        to a stopped pool raises [Invalid_argument]. *)
  end

  module type POOL = sig
    val pool : pool
  end

  module Make (_ : POOL) : sig
    val run :
      ?name:string -> ('input -> 'output) -> 'input -> ('output, 'err) Eta.Effect.t

    val map :
      ?name:string ->
      f:('input -> 'output) ->
      'input list ->
      ('output list, 'err) Eta.Effect.t

    val map_result :
      ?name:string ->
      f:('input -> ('output, 'error) result) ->
      'input list ->
      (('output, 'error) result list, 'err) Eta.Effect.t

    val all_settled :
      ?name:string ->
      f:('input -> ('output, 'error) result) ->
      'input list ->
      (('output, 'error) settled list, 'err) Eta.Effect.t
  end
end
