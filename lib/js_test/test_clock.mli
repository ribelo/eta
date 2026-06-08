type t

val create : unit -> t
val now_ms : t -> int
val sleep : t -> Eta_js.Duration.t -> (unit, 'err) Eta_js.Effect.t
val adjust : t -> Eta_js.Duration.t -> (unit, 'err) Eta_js.Effect.t
val set_time : t -> int -> (unit, 'err) Eta_js.Effect.t
val sleeper_count : t -> int
val clock : t -> Eta_js.Runtime_core.clock
val runtime : ?scheduler:Eta_js.Scheduler.t -> t -> 'err Eta_js.Runtime.t
