(** Refreshable cached values.

    A refreshable value stores a loader and the last successfully loaded value.
    Refreshing publishes a new value only after the loader succeeds, so readers
    keep seeing the last good value while a refresh runs or fails. *)

open Eta

type ('a, 'err) t

val manual :
  ('a, 'err) Effect.t ->
  (('a, 'err) t, 'err) Effect.t
(** Load once to seed a caller-refreshed value. If the load fails, no handle is
    returned. *)

val with_auto :
  load:('a, 'err) Effect.t ->
  schedule:(unit, 'schedule_out) Schedule.t ->
  (('a, 'err) t -> ('b, 'err) Effect.t) ->
  ('b, 'err) Effect.t
(** Load once before [body] runs, then refresh according to [schedule] while
    [body] uses the handle. Seed failure fails the effect without running
    [body].

    The refresh loop is owned by this lexical call. When [body] exits with
    success, typed failure, defect, or cancellation, the loop is cancelled and
    awaited; an in-flight refresh is cancelled at a checkpoint and its
    finalizers run before the call exits. Schedule exhaustion ends only the
    refresh loop: [body] continues with a usable handle and its last good value.
    Use {!Effect.with_random} to inject deterministic randomness for schedule
    jitter; otherwise the loop uses the runtime's current random source.

    Refresh failures keep the last good value. {!failures} records typed loader
    failures as [Cause.Fail err] and loader defects as [Cause.Die _]; neither
    stops later refresh attempts.

    Instrument [load] to observe load attempts; use an application-owned counter
    when seed and refresh attempts need distinct labels. This observes loads,
    not terminal schedule exhaustion or other schedule-local boundaries. *)

val with_auto_on_refresh_error :
  on_refresh_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  schedule:(unit, 'schedule_out) Schedule.t ->
  (('a, 'err) t -> ('b, 'err) Effect.t) ->
  ('b, 'err) Effect.t
(** The explicit alerting form of {!with_auto}. [on_refresh_error] runs only for
    typed automatic refresh failures: seed failure fails before the body and
    never calls it, and body failures and defects do not call it. If the callback
    raises, its defect is recorded as an additional [Cause.Die _] after the typed
    refresh failure and later refreshes continue. *)

val get : ('a, 'err) t -> ('a, 'err) Effect.t
(** Return the last successfully loaded value. *)

val refresh : ('a, 'err) t -> (unit, 'err) Effect.t
(** Run the loader once. Success publishes the new value; failure leaves the
    last good value unchanged. *)

val failures : ('a, 'err) t -> ('err Cause.t list, 'outer_err) Effect.t
(** Return automatic refresh failures in observation order. Manual values start
    with an empty list. A typed automatic refresh failure is recorded before
    [on_refresh_error] runs. *)
