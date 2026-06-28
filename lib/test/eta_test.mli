(** Testing helpers for Eta programs.

    The v1 surface follows Eta's runtime seams rather than cloning
    eff-smol's test services. See .scratch/research/journal.md, TestClock port near line 529,
    and V-CM-H2-C1 for the portable random token rationale. *)

module Test_clock : sig
  type t
  (** A virtual clock for tests that drive Eta runtime sleep manually. *)

  val create : unit -> t
  (** [create ()] starts a virtual clock at millisecond 0. *)

  val sleep : t -> Eta.Duration.t -> unit
  (** [sleep clock duration] is passed to [Eta_eio.Runtime.create ~sleep]. *)

  val adjust : t -> Eta.Duration.t -> unit
  (** [adjust clock (Duration.ms 10)] advances virtual time and wakes due
      sleepers. *)

  val set_time : t -> int -> unit
  (** [set_time clock 100] moves virtual time to millisecond 100. *)

  val now_ms : t -> int
  (** [now_ms clock] returns the current virtual millisecond timestamp. *)

  val sleeper_count : t -> int
  (** [sleeper_count clock] returns the number of fibers waiting on the test
      clock. *)
end

val with_logger :
  (Eio.Switch.t -> 'err Eta.Runtime.t -> Eta.Logger.in_memory -> 'a) -> 'a
(** [with_logger f] creates a runtime with an in-memory logger. *)

val with_tracer :
  (Eio.Switch.t -> 'err Eta.Runtime.t -> Eta.Tracer.in_memory -> 'a) -> 'a
(** [with_tracer f] creates a runtime with an in-memory tracer. *)

val with_logger_and_tracer :
  (Eio.Switch.t ->
  'err Eta.Runtime.t ->
  Eta.Logger.in_memory ->
  Eta.Tracer.in_memory ->
  'a) ->
  'a
(** [with_logger_and_tracer f] creates a runtime with both in-memory
    observability capabilities. *)

val with_test_clock :
  (Eio.Switch.t -> Test_clock.t -> 'err Eta.Runtime.t -> 'a) -> 'a
(** [with_test_clock (fun sw clock rt -> ...)] creates a runtime whose
    [Effect.delay], [Effect.timeout], [Effect.repeat], and [Effect.retry]
    sleeps are controlled by [clock]. *)

val with_traced_test_clock :
  (Eio.Switch.t ->
  Test_clock.t ->
  'err Eta.Runtime.t ->
  Eta.Tracer.in_memory ->
  'a) ->
  'a
(** [with_traced_test_clock f] is [with_test_clock] plus an in-memory tracer,
    matching the virtual-time traced test patterns in Eta's own suite. *)

module Async : sig
  type 'a promise = 'a Eio.Promise.t
  (** Promise returned by Eta test helpers. *)

  val fork_run :
    Eio.Switch.t ->
    'err Eta.Runtime.t ->
    ('a, 'err) Eta.Effect.t ->
    ('a, 'err) Eta.Exit.t promise
  (** [fork_run sw rt eff] runs [eff] on [rt] in a child fiber and
      resolves the returned promise with its [Exit.t]. *)

  val await : 'a promise -> 'a
  (** [await promise] blocks until [promise] resolves. *)

  val unresolved : unit -> 'a promise
  (** [unresolved ()] returns a promise that remains unresolved unless an
      external fixture resolves it. *)

  val yield : unit -> unit
  (** Yield to sibling fibers in tests that need to observe concurrent state. *)
end

module Expect : sig
  val expect_ok : ('a, 'err) Eta.Exit.t -> 'a
  (** [expect_ok exit] returns the success value or fails the Alcotest case. *)

  val expect_typed_failure : ('a, 'err) Eta.Exit.t -> ('err -> bool) -> unit
  (** [expect_typed_failure exit predicate] accepts only [Eta.Cause.Fail] values
      matching the predicate. *)

  val expect_typed_failure_eq :
    'err Alcotest.testable -> ('a, 'err) Eta.Exit.t -> 'err -> unit
  (** [expect_typed_failure_eq err_test exit expected] checks a typed failure
      with an Alcotest testable. *)

  val expect_die : ('a, 'err) Eta.Exit.t -> (Eta.Cause.die -> bool) -> unit
  (** [expect_die exit (fun die -> die.exn == exn)] accepts matching unchecked
      defects. *)

  val expect_interrupt : ('a, 'err) Eta.Exit.t -> unit
  (** [expect_interrupt exit] accepts [Eta.Cause.Interrupt _]. *)
end

module Test_random : sig
  val create : seed:int -> Eta.Capabilities.random
  (** [create ~seed:42] returns a deterministic portable random token. *)

  val set_seed : Eta.Capabilities.random -> int -> unit
  (** [set_seed random 42] resets the token for deterministic test replay. *)
end
