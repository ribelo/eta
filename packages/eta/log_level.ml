type t =
  | All
  | Trace
  | Debug
  | Info
  | Warn
  | Error
  | Fatal
  | None

let to_string = function
  | All -> "ALL"
  | Trace -> "TRACE"
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"
  | Fatal -> "FATAL"
  | None -> "NONE"

let of_string s =
  match String.uppercase_ascii s with
  | "ALL" -> Some All
  | "TRACE" -> Some Trace
  | "DEBUG" -> Some Debug
  | "INFO" -> Some Info
  | "WARN" -> Some Warn
  | "ERROR" -> Some Error
  | "FATAL" -> Some Fatal
  | "NONE" -> Some None
  | _ -> None

let to_rank = function
  | All -> 0
  | Trace -> 1
  | Debug -> 2
  | Info -> 3
  | Warn -> 4
  | Error -> 5
  | Fatal -> 6
  | None -> 7

let compare a b = Int.compare (to_rank a) (to_rank b)
let equal a b = compare a b = 0

let is_enabled ~at ~threshold =
  match threshold with
  | None -> false
  | All -> true
  | _ -> at <> None && compare at threshold >= 0

let to_otel_severity = function
  | All -> 0
  | Trace -> 1
  | Debug -> 5
  | Info -> 9
  | Warn -> 13
  | Error -> 17
  | Fatal -> 21
  | None -> 0

let of_otel_severity n =
  if n <= 0 then All
  else if n < 5 then Trace
  else if n < 9 then Debug
  else if n < 13 then Info
  else if n < 17 then Warn
  else if n < 21 then Error
  else Fatal

let pp fmt t = Format.pp_print_string fmt (to_string t)

let all = [ All; Trace; Debug; Info; Warn; Error; Fatal; None ]
