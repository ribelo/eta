type timeout_id
type abort_controller
type abort_signal

val date_now : unit -> float
val set_timeout : (unit -> unit) -> int -> timeout_id
val clear_timeout : timeout_id -> unit
val queue_microtask : (unit -> unit) -> unit
val make_abort_controller : unit -> abort_controller
val signal : abort_controller -> abort_signal
val abort : abort_controller -> unit
val aborted : abort_signal -> bool
