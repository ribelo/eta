type timeout_id
type abort_controller
type abort_signal

external date_now : unit -> float = "now" [@@mel.scope "Date"]
external set_timeout : (unit -> unit) -> int -> timeout_id = "setTimeout"
external clear_timeout : timeout_id -> unit = "clearTimeout"
external queue_microtask : (unit -> unit) -> unit = "queueMicrotask"

external make_abort_controller : unit -> abort_controller = "AbortController"
[@@mel.new]

external signal : abort_controller -> abort_signal = "signal" [@@mel.get]
external abort : abort_controller -> unit = "abort" [@@mel.send]
external aborted : abort_signal -> bool = "aborted" [@@mel.get]
