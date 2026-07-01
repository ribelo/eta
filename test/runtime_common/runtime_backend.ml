module type S = sig
  type ctx
  type clock
  type 'a promise
  type 'a resolver
  type 'a stream
  type 'a cancelable

  val name : string

  val with_runtime : (ctx -> 'err Eta.Runtime.t -> 'a) -> 'a

  val with_runtime_contract : (ctx -> Eta.Runtime_contract.t -> 'a) -> 'a

  val with_traced_runtime :
    (ctx -> 'err Eta.Runtime.t -> Eta.Tracer.in_memory -> 'a) -> 'a

  val with_custom_tracer_runtime :
    Eta.Capabilities.tracer -> (ctx -> 'err Eta.Runtime.t -> 'a) -> 'a

  val with_sampled_traced_runtime :
    Eta.Sampler.t ->
    (ctx -> 'err Eta.Runtime.t -> Eta.Tracer.in_memory -> 'a) ->
    'a

  val with_seeded_sampled_traced_runtime :
    seed:int ->
    Eta.Sampler.t ->
    (ctx -> 'err Eta.Runtime.t -> Eta.Tracer.in_memory -> 'a) ->
    'a

  val with_auto_traced_runtime :
    bool -> (ctx -> 'err Eta.Runtime.t -> Eta.Tracer.in_memory -> 'a) -> 'a

  val with_meter_runtime :
    (ctx -> 'err Eta.Runtime.t -> Eta.Meter.in_memory -> 'a) -> 'a

  val with_meter_test_clock :
    (ctx -> clock -> 'err Eta.Runtime.t -> Eta.Meter.in_memory -> 'a) -> 'a

  val with_logger_runtime :
    (ctx -> 'err Eta.Runtime.t -> Eta.Logger.in_memory -> 'a) -> 'a

  val with_observed_runtime :
    (ctx ->
    'err Eta.Runtime.t ->
    Eta.Tracer.in_memory ->
    Eta.Logger.in_memory ->
    Eta.Meter.in_memory ->
    'a) ->
    'a

  val with_runtime_capture_backtrace :
    bool -> (ctx -> 'err Eta.Runtime.t -> 'a) -> 'a

  val with_test_clock : (ctx -> clock -> 'err Eta.Runtime.t -> 'a) -> 'a

  val with_traced_test_clock :
    (ctx -> clock -> 'err Eta.Runtime.t -> Eta.Tracer.in_memory -> 'a) -> 'a

  val with_seeded_test_clock :
    seed:int -> (ctx -> clock -> 'err Eta.Runtime.t -> 'a) -> 'a

  val with_seeded_logged_test_clock :
    seed:int ->
    (ctx -> clock -> 'err Eta.Runtime.t -> Eta.Duration.t list ref -> 'a) ->
    'a

  val run :
    'err Eta.Runtime.t ->
    ('a, 'err) Eta.Effect.t ->
    ('a, 'err) Eta.Exit.t

  val run_exn : 'err Eta.Runtime.t -> ('a, 'err) Eta.Effect.t -> 'a

  val drain : 'err Eta.Runtime.t -> unit

  val fork_run :
    ctx ->
    'err Eta.Runtime.t ->
    ('a, 'err) Eta.Effect.t ->
    ('a, 'err) Eta.Exit.t promise

  val fork_run_cancelable :
    ctx ->
    'err Eta.Runtime.t ->
    ('a, 'err) Eta.Effect.t ->
    (('a, 'err) Eta.Exit.t) cancelable

  val cancel_fiber : 'a cancelable -> unit
  val await_cancelable : 'a cancelable -> [ `Returned of 'a | `Cancelled ]

  val await : 'a promise -> 'a
  val is_resolved : 'a promise -> bool
  val yield : unit -> unit
  val yield_effect : unit -> (unit, 'err) Eta.Effect.t

  val create_promise : unit -> 'a promise * 'a resolver
  val resolve : 'a resolver -> 'a -> unit
  val try_resolve : 'a resolver -> 'a -> unit
  val await_effect : 'a promise -> ('a, 'err) Eta.Effect.t
  val await_cancel_effect : unit -> ('a, 'err) Eta.Effect.t

  val create_stream : int -> 'a stream
  val stream_add : 'a stream -> 'a -> unit
  val stream_take : 'a stream -> 'a

  val adjust_clock : clock -> Eta.Duration.t -> unit
  val set_clock : clock -> int -> unit
  val sleeper_count : clock -> int
end
