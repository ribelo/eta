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
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
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

    Refresh failures keep the last good value and call [on_error] for typed
    failures when provided. {!failures} records typed loader failures as
    [Cause.Fail err] and loader defects as [Cause.Die _]; neither stops later
    refresh attempts. If [on_error] raises, that callback defect is recorded as
    an additional [Cause.Die _] after the typed failure and the loop continues.

    Instrument [load] to observe load attempts; use an application-owned counter
    when seed and refresh attempts need distinct labels. This observes loads,
    not terminal schedule exhaustion or other schedule-local boundaries. *)

val get : ('a, 'err) t -> ('a, 'err) Effect.t
(** Return the last successfully loaded value. *)

val refresh : ('a, 'err) t -> (unit, 'err) Effect.t
(** Run the loader once. Success publishes the new value; failure leaves the
    last good value unchanged. *)

val failures : ('a, 'err) t -> ('err Cause.t list, 'outer_err) Effect.t
(** Return automatic refresh failures in observation order. Manual values start
    with an empty list. A typed automatic refresh failure is recorded before
    [on_error] runs. *)
