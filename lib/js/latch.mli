type t

val make : unit -> (t, 'err) Effect_core.t
val make_unsafe : unit -> t
val await : t -> (unit, 'err) Effect_core.t
val release : t -> (bool, 'err) Effect_core.t
val is_released : t -> bool
