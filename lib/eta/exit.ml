type ('a, 'err) t =
  | Ok of 'a
  | Error of 'err Cause.t

let map f = function Ok value -> Ok (f value) | Error cause -> Error cause
let map_error f = function Ok value -> Ok value | Error cause -> Error (Cause.map f cause)

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
