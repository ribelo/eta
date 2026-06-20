type ('a, 'err) t =
  | Ok of 'a
  | Error of 'err Cause.t

let ok value = Ok value
let error cause = Error cause

let is_ok = function Ok _ -> true | Error _ -> false
let is_error exit = not (is_ok exit)
let get_success = function Ok value -> Some value | Error _ -> None
let get_cause = function Ok _ -> None | Error cause -> Some cause
let match_ ~ok ~error = function Ok value -> ok value | Error cause -> error cause
let map f = function Ok value -> Ok (f value) | Error cause -> Error cause
let map_error f = function Ok value -> Ok value | Error cause -> Error (Cause.map f cause)

let map_both ~ok ~error = function
  | Ok value -> Ok (ok value)
  | Error cause -> Error (Cause.map error cause)

let get_or_else on_error = function
  | Ok value -> value
  | Error cause -> on_error cause

let as_unit = function Ok _ -> Ok () | Error cause -> Error cause

let to_result = function
  | Ok value -> Some (Stdlib.Ok value)
  | Error (Cause.Fail err) -> Some (Stdlib.Error err)
  | Error
      ( Cause.Die _ | Interrupt _ | Sequential _ | Concurrent _ | Finalizer _
      | Suppressed _ )
    ->
      None

let equal equal_a equal_err left right =
  match (left, right) with
  | Ok a, Ok b -> equal_a a b
  | Error a, Error b -> Cause.equal equal_err a b
  | _ -> false

let pp pp_a pp_err fmt = function
  | Ok value -> Format.fprintf fmt "Ok(%a)" pp_a value
  | Error cause -> Format.fprintf fmt "Error(%a)" (Cause.pp pp_err) cause

let pretty render_value render_error = function
  | Ok value -> "Ok(" ^ render_value value ^ ")"
  | Error cause -> "Error(" ^ Cause.pretty render_error cause ^ ")"
