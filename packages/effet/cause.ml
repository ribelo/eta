type 'err t =
  | Fail of 'err
  | Die of exn
  | Interrupt
  | Both of 'err t * 'err t

let fail err = Fail err
let die exn = Die exn
let interrupt = Interrupt
let both left right = Both (left, right)

let rec equal equal_err left right =
  match (left, right) with
  | Fail a, Fail b -> equal_err a b
  | Die a, Die b -> a == b
  | Interrupt, Interrupt -> true
  | Both (al, ar), Both (bl, br) ->
      equal equal_err al bl && equal equal_err ar br
  | _ -> false

let rec pp pp_err fmt = function
  | Fail err -> Format.fprintf fmt "Fail(%a)" pp_err err
  | Die exn -> Format.fprintf fmt "Die(%s)" (Printexc.to_string exn)
  | Interrupt -> Format.pp_print_string fmt "Interrupt"
  | Both (left, right) ->
      Format.fprintf fmt "Both(%a, %a)" (pp pp_err) left (pp pp_err) right
