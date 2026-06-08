type timer_cancel = unit -> unit

type clock = {
  now_ms : unit -> int;
  sleep : Duration.t -> (unit -> unit) -> timer_cancel;
}

val default_clock : unit -> clock

type 'err t = {
  scheduler : Scheduler.t;
  clock : clock;
  tracer : Capabilities.tracer option;
  sampler : Sampler.t;
  logger : Capabilities.logger option;
  meter : Capabilities.meter option;
  random : Capabilities.random;
  capture_backtrace : bool;
  mutable daemon_count : int;
  mutable daemon_waiters : (unit -> unit) list;
}

val create :
  ?scheduler:Scheduler.t ->
  ?clock:clock ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?capture_backtrace:bool ->
  unit ->
  'err t

val daemon_started : 'err t -> unit
val daemon_finished : 'err t -> unit
val daemon_failed : 'err t -> Obj.t Cause.t -> unit
val drain_promise : 'err t -> unit Js.Promise.t
