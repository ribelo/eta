type ('a, 'err) t =
  | Ok of 'a
  | Error of 'err Cause.t

let ok value = Ok value
let error cause = Error cause

let to_result = function
  | Ok value -> Some (Stdlib.Ok value)
  | Error (Cause.Fail err) -> Some (Stdlib.Error err)
  | Error
      ( Cause.Die _ | Interrupt _ | Sequential _ | Concurrent _ | Suppressed _ )
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
