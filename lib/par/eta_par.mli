(** Eta_par — a parallel runtime for OxCaml.

    Eta_par offers fork-join data parallelism on multiple cores.
    Internally it implements the heartbeat scheduling algorithm of
    Acar et al.: parallel work runs sequentially on the calling
    worker's cactus stack, and the OLDEST queued frame is promoted
    into a stealable slot only at periodic heartbeat ticks.  See
    the original heartbeat paper and the Spice (Zig) and chili (Rust)
    implementations for the prior art.  The public surface is
    deliberately small: pools, [run], [join], and a handful of
    Rayon-shaped combinators.

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
    ?n_workers:int -> ?heartbeat_interval_ns:int -> unit -> t
  (** Create a pool with [n_workers] workers (default:
      [Domain.recommended_domain_count ()]).  Worker 0 is reserved
      for the caller of {!run}; workers 1..n-1 each spawn a domain
      that idles on a condvar waiting for work.  A separate domain
      ticks every worker's heartbeat flag round-robin every
      [heartbeat_interval_ns] nanoseconds (default 100 µs).  The pool
      stays alive until {!shutdown} is called. *)

  val run : t -> (unit -> 'a) -> 'a
  (** [run pool f] runs [f] as the root task on the calling thread.  The
      caller participates as worker 0 for the duration of the call.

      Calling [run] concurrently on the same pool is not supported. *)

  val run_on_worker : t -> (unit -> 'a) -> 'a
  (** [run_on_worker pool f] schedules [f] on a long-lived worker domain and
      blocks the caller until it returns.  If the pool has no background
      workers, [f] runs inline.

      This is the entry point for typed offload wrappers such as
      [Effect.island].  Use {!run} for explicit fork-join roots where the
      caller should participate as worker 0. *)

  val run_many_on_workers : t -> (unit -> 'a) list -> 'a list
  (** [run_many_on_workers pool jobs] schedules all [jobs] on long-lived
      worker domains and returns results in input order after every job
      finishes.  If any job raises, all jobs still finish and the first
      exception in input order is re-raised. *)

  val shutdown : t -> unit
  (** Signal all worker domains to exit and join them.  Calling [run]
      after shutdown is undefined. *)

  val with_pool :
    ?n_workers:int -> ?heartbeat_interval_ns:int -> (t -> 'a) -> 'a
  (** [with_pool ?n_workers f] = [create ?n_workers (), f, shutdown]. *)
end

(** {1 Top-level runner} *)

val run :
  ?n_workers:int -> ?heartbeat_interval_ns:int -> (unit -> 'a) -> 'a
(** Convenience: create a pool, run [f], shut down.  Use {!Pool.run} if
    you want to reuse the pool across multiple top-level calls. *)

(** {1 Fork-join} *)

val join : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
(** [join f g] runs [f] and [g] potentially in parallel and returns
    both results.

    Must be called from inside a task running on a pool worker (i.e.,
    transitively from {!run} or {!Pool.run}).

    Under the heartbeat algorithm, [f] is pushed onto the worker's
    cactus stack and [g] runs inline.  At periodic heartbeat ticks the
    OLDEST frame on the stack — possibly [f], possibly some
    grandparent of [f] — is promoted into a stealable slot.  If [f]
    actually got promoted and picked up by another worker the joiner
    waits for its result; otherwise [f] runs inline after [g] with no
    extra overhead.  Exceptions raised by either side propagate to the
    caller, with the other side's work always run to completion first
    (so children cannot leak the parent's frame). *)

val join3 :
  (unit -> 'a) -> (unit -> 'b) -> (unit -> 'c) -> 'a * 'b * 'c
(** Three-way fork-join. *)

(** {1 Parallel iteration} *)

val par_for :
  ?chunk:int -> start:int -> stop:int -> (int -> unit) -> unit
(** [par_for ?chunk ~start ~stop f] applies [f] to every integer in
    [[start, stop)] in parallel.  The range is recursively halved until
    each leaf is at most [chunk] integers wide; below that it runs
    serially.  [chunk] defaults to {!par_threshold}.  Pass a smaller
    [chunk] for kernels with heavy per-iteration work and few
    iterations (e.g., [par_for ~chunk:1] over rows of a matmul). *)

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

(** {1 Tuning} *)

val par_threshold : int ref
(** Default minimum chunk size for combinators that don't get a
    [?chunk] argument.  Lower values create more tasks and finer load
    balancing at the cost of scheduling overhead.  Default: 1024. *)

(** {1 Lazy parallel iterators}

    Rayon-style iterator chains, layered on top of {!join}.  Construct
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
