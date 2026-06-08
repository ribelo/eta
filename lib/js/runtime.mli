type 'err t = 'err Runtime_core.t

val create :
  ?scheduler:Scheduler.t ->
  ?clock:Runtime_core.clock ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?capture_backtrace:bool ->
  unit ->
  'err t

val run_promise :
  'err t ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Exit.t Js.Promise.t

val run_now : 'err t -> ('a, 'err) Effect.t -> ('a, 'err) Exit.t option
val drain_promise : 'err t -> unit Js.Promise.t
