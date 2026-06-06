(** Same-runtime bounded resource pool.

    Pool owns bounded checkout/release of ordinary runtime-local values such as
    HTTP/1.1 or SQL connections. It is not a cross-domain payload handoff
    primitive.

    The pool stores idle resources in LIFO order for warm reuse. Waiting
    acquirers use a private wake-one queue; cancellation removes the waiter
    slot and increments [cancelled_waiters].

    Out of scope for this module: HTTP/2 multiplexers, keyed cohort maps,
    Treiber/portable backends, cross-domain payloads, and local-unique borrow
    APIs. *)

type ('conn, 'err) t

type stats = {
  active : int;
  idle : int;
  waiting : int;
  max_size : int;
  opened : int;
  closed : int;
  health_rejected : int;
  cancelled_waiters : int;
  shutting_down : bool;
}

val create :
  ?name:string ->
  ?kind:string ->
  max_size:int ->
  ?max_idle:int ->
  ?idle_lifetime:Duration.t ->
  ?max_lifetime:Duration.t ->
  ?idle_check_interval:Duration.t ->
  acquire:('conn, ([> `Pool_shutdown ] as 'err)) Effect.t ->
  release:('conn -> (unit, 'err) Effect.t) ->
  ?health_check:('conn -> (unit, 'err) Effect.t) ->
  unit ->
  (('conn, 'err) t, 'err) Effect.t
(** Create a pool.

    [max_size] bounds resources that are idle, checked out, opening, or
    closing. [max_idle] defaults to [max_size]. [health_check] defaults to
    accepting every resource.

    If [idle_lifetime] or [max_lifetime] is provided, a runtime-owned daemon
    evicts expired idle resources at [idle_check_interval], which defaults to
    1 second.

    @raise Invalid_argument if [max_size <= 0], [max_idle < 0],
    [max_idle > max_size], or [idle_check_interval <= 0]. *)

val with_resource :
  ('conn, ([> `Pool_shutdown ] as 'err)) t ->
  ('conn -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t
(** Acquire one resource, run [body], and release the resource when [body]
    finishes, fails, or is cancelled.

    Fails with [`Pool_shutdown] if the pool is shutting down before a resource
    can be acquired. *)

val shutdown :
  ?deadline:Duration.t ->
  ('conn, ([> `Pool_shutdown_timeout ] as 'err)) t ->
  (unit, 'err) Effect.t
(** Stop new acquires, wake pending waiters with [`Pool_shutdown], close idle
    resources, and wait for checked-out resources to return.

    If [deadline] expires before in-use resources drain, fails with
    [`Pool_shutdown_timeout]. Returned resources are still closed after the
    timeout because the pool remains in shutdown state. *)

val stats : ('conn, 'err) t -> stats
(** Snapshot pool counters. *)
