type interrupt_id = int

type 'err t =
  | Fail of 'err
  | Die of exn * Printexc.raw_backtrace option
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Suppressed of { primary : 'err t; finalizer : 'err t }

let fail err = Fail err
let die exn = Die (exn, None)
let die_with_backtrace exn bt = Die (exn, Some bt)
let interrupt = Interrupt None
let interrupt_with_id id = Interrupt (Some id)

let sequential = function
  | [] -> die (Invalid_argument "Cause.sequential: empty")
  | [ one ] -> one
  | causes -> Sequential causes

let concurrent = function
  | [] -> die (Invalid_argument "Cause.concurrent: empty")
  | [ one ] -> one
  | causes -> Concurrent causes

let suppressed ~primary ~finalizer = Suppressed { primary; finalizer }

let rec is_interrupt_only = function
  | Interrupt _ -> true
  | Sequential causes | Concurrent causes -> List.for_all is_interrupt_only causes
  | Suppressed { primary; finalizer } ->
      is_interrupt_only primary && is_interrupt_only finalizer
  | Fail _ | Die _ -> false

let equal_option equal_a left right =
  match (left, right) with
  | None, None -> true
  | Some a, Some b -> equal_a a b
  | _ -> false

let equal_list equal_a left right =
  List.length left = List.length right && List.for_all2 equal_a left right

let rec equal equal_err left right =
  match (left, right) with
  | Fail a, Fail b -> equal_err a b
  | Die (a, _), Die (b, _) -> a == b
  | Interrupt a, Interrupt b -> equal_option Int.equal a b
  | Sequential a, Sequential b | Concurrent a, Concurrent b ->
      equal_list (equal equal_err) a b
  | Suppressed a, Suppressed b ->
      equal equal_err a.primary b.primary
      && equal equal_err a.finalizer b.finalizer
  | _ -> false

let rec pp pp_err fmt = function
  | Fail err -> Format.fprintf fmt "Fail(%a)" pp_err err
  | Die (exn, _) -> Format.fprintf fmt "Die(%s)" (Printexc.to_string exn)
  | Interrupt None -> Format.pp_print_string fmt "Interrupt"
  | Interrupt (Some id) -> Format.fprintf fmt "Interrupt(%d)" id
  | Sequential causes ->
      Format.fprintf fmt "Sequential[%a]"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
           (pp pp_err))
        causes
  | Concurrent causes ->
      Format.fprintf fmt "Concurrent[%a]"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
           (pp pp_err))
        causes
  | Suppressed { primary; finalizer } ->
      Format.fprintf fmt "Suppressed{primary=%a; finalizer=%a}" (pp pp_err)
        primary (pp pp_err) finalizer
