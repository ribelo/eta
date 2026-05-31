type interrupt_id : immutable_data = int

type die = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
  span_name : string option;
  annotations : (string * string) list;
}

let equal_option equal_a left right =
  match (left, right) with
  | None, None -> true
  | Some a, Some b -> equal_a a b
  | _ -> false

let equal_list equal_a left right =
  List.length left = List.length right && List.for_all2 equal_a left right

let equal_die left right =
  left.exn == right.exn
  && equal_option String.equal left.span_name right.span_name
  && equal_list
       (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
       left.annotations right.annotations

let backtrace_string die = Option.map Printexc.raw_backtrace_to_string die.backtrace

let diagnostic_equal_die left right =
  String.equal (Printexc.exn_slot_name left.exn)
    (Printexc.exn_slot_name right.exn)
  && String.equal (Printexc.to_string left.exn) (Printexc.to_string right.exn)
  && equal_option String.equal (backtrace_string left) (backtrace_string right)
  && equal_option String.equal left.span_name right.span_name
  && equal_list
       (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
       left.annotations right.annotations

let pp_annotations fmt annotations =
  Format.fprintf fmt "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
       (fun fmt (key, value) -> Format.fprintf fmt "%s=%S" key value))
    annotations

let pp_backtrace fmt = function
  | None -> ()
  | Some bt ->
      Format.fprintf fmt "; backtrace=%S" (Printexc.raw_backtrace_to_string bt)

let pp_die fmt die =
  Format.fprintf fmt "Die{exn=%S" (Printexc.to_string die.exn);
  (match die.span_name with
  | None -> ()
  | Some name -> Format.fprintf fmt "; span_name=%S" name);
  (match die.annotations with
  | [] -> ()
  | annotations ->
      Format.fprintf fmt "; annotations=%a" pp_annotations annotations);
  pp_backtrace fmt die.backtrace;
  Format.pp_print_string fmt "}"

module Finalizer = struct
  type t =
    | Fail of string
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of t list
    | Concurrent of t list
    | Finalizer of t
    | Suppressed of { primary : t; finalizer : t }

  let rec equal left right =
    match (left, right) with
    | Fail a, Fail b -> String.equal a b
    | Die a, Die b -> equal_die a b
    | Interrupt a, Interrupt b -> equal_option Int.equal a b
    | Sequential a, Sequential b | Concurrent a, Concurrent b ->
        equal_list equal a b
    | Finalizer a, Finalizer b -> equal a b
    | Suppressed a, Suppressed b ->
        equal a.primary b.primary && equal a.finalizer b.finalizer
    | _ -> false

  let rec diagnostic_equal left right =
    match (left, right) with
    | Fail a, Fail b -> String.equal a b
    | Die a, Die b -> diagnostic_equal_die a b
    | Interrupt a, Interrupt b -> equal_option Int.equal a b
    | Sequential a, Sequential b | Concurrent a, Concurrent b ->
        equal_list diagnostic_equal a b
    | Finalizer a, Finalizer b -> diagnostic_equal a b
    | Suppressed a, Suppressed b ->
        diagnostic_equal a.primary b.primary
        && diagnostic_equal a.finalizer b.finalizer
    | _ -> false

  let rec pp fmt = function
    | Fail err -> Format.fprintf fmt "Fail(%S)" err
    | Die die -> pp_die fmt die
    | Interrupt None -> Format.pp_print_string fmt "Interrupt"
    | Interrupt (Some id) -> Format.fprintf fmt "Interrupt(%d)" id
    | Sequential causes ->
        Format.fprintf fmt "Sequential[%a]"
          (Format.pp_print_list
             ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
             pp)
          causes
    | Concurrent causes ->
        Format.fprintf fmt "Concurrent[%a]"
          (Format.pp_print_list
             ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
             pp)
          causes
    | Finalizer cause -> Format.fprintf fmt "Finalizer(%a)" pp cause
    | Suppressed { primary; finalizer } ->
        Format.fprintf fmt "Suppressed{primary=%a; finalizer=%a}" pp primary pp
          finalizer

  let rec is_interrupt_only = function
    | Interrupt _ -> true
    | Sequential causes | Concurrent causes -> List.for_all is_interrupt_only causes
    | Finalizer cause -> is_interrupt_only cause
    | Suppressed { primary; finalizer } ->
        is_interrupt_only primary && is_interrupt_only finalizer
    | Fail _ | Die _ -> false
end

module Finalizer_cause = Finalizer

type 'err t =
  | Fail of 'err
  | Die of die
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Finalizer of Finalizer.t
  | Suppressed of { primary : 'err t; finalizer : Finalizer.t }

type 'err same_domain_t = 'err t

module Portable = struct
  type die : value mod portable = {
    kind : string;
    message : string;
    backtrace : string option;
    span_name : string option;
    annotations : (string * string) list;
  }

  module Finalizer = struct
    type t : value mod portable =
      | Fail of string
      | Die of die
      | Interrupt of interrupt_id option
      | Sequential of t list
      | Concurrent of t list
      | Finalizer of t
      | Suppressed of { primary : t; finalizer : t }

    let die_of_cause die =
      {
        kind = Printexc.exn_slot_name die.exn;
        message = Printexc.to_string die.exn;
        backtrace = Option.map Printexc.raw_backtrace_to_string die.backtrace;
        span_name = die.span_name;
        annotations = die.annotations;
      }

    let rec of_finalizer : Finalizer_cause.t -> t = function
      | Finalizer_cause.Fail err -> Fail err
      | Finalizer_cause.Die die -> Die (die_of_cause die)
      | Finalizer_cause.Interrupt id -> Interrupt id
      | Finalizer_cause.Sequential causes -> Sequential (List.map of_finalizer causes)
      | Finalizer_cause.Concurrent causes -> Concurrent (List.map of_finalizer causes)
      | Finalizer_cause.Finalizer cause -> Finalizer (of_finalizer cause)
      | Finalizer_cause.Suppressed { primary; finalizer } ->
          Suppressed
            {
              primary = of_finalizer primary;
              finalizer = of_finalizer finalizer;
            }

    let equal_die left right =
      String.equal left.kind right.kind
      && String.equal left.message right.message
      && equal_option String.equal left.backtrace right.backtrace
      && equal_option String.equal left.span_name right.span_name
      && equal_list
           (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
           left.annotations right.annotations

    let rec equal left right =
      match (left, right) with
      | Fail a, Fail b -> String.equal a b
      | Die a, Die b -> equal_die a b
      | Interrupt a, Interrupt b -> equal_option Int.equal a b
      | Sequential a, Sequential b | Concurrent a, Concurrent b ->
          equal_list equal a b
      | Finalizer a, Finalizer b -> equal a b
      | Suppressed a, Suppressed b ->
          equal a.primary b.primary && equal a.finalizer b.finalizer
      | _ -> false

    let pp_backtrace fmt = function
      | None -> ()
      | Some bt -> Format.fprintf fmt "; backtrace=%S" bt

    let pp_die fmt die =
      Format.fprintf fmt "Die{kind=%S; message=%S" die.kind die.message;
      (match die.span_name with
      | None -> ()
      | Some name -> Format.fprintf fmt "; span_name=%S" name);
      (match die.annotations with
      | [] -> ()
      | annotations ->
          Format.fprintf fmt "; annotations=%a" pp_annotations annotations);
      pp_backtrace fmt die.backtrace;
      Format.pp_print_string fmt "}"

    let rec pp fmt = function
      | Fail err -> Format.fprintf fmt "Fail(%S)" err
      | Die die -> pp_die fmt die
      | Interrupt None -> Format.pp_print_string fmt "Interrupt"
      | Interrupt (Some id) -> Format.fprintf fmt "Interrupt(%d)" id
      | Sequential causes ->
          Format.fprintf fmt "Sequential[%a]"
            (Format.pp_print_list
               ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
               pp)
            causes
      | Concurrent causes ->
          Format.fprintf fmt "Concurrent[%a]"
            (Format.pp_print_list
               ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
               pp)
            causes
      | Finalizer cause -> Format.fprintf fmt "Finalizer(%a)" pp cause
      | Suppressed { primary; finalizer } ->
          Format.fprintf fmt "Suppressed{primary=%a; finalizer=%a}" pp primary pp
            finalizer
  end

  type ('err : value mod portable) t : value mod portable =
    | Fail of 'err
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Finalizer of Finalizer.t
    | Suppressed of { primary : 'err t; finalizer : Finalizer.t }

  let die_of_cause die =
    {
      kind = Printexc.exn_slot_name die.exn;
      message = Printexc.to_string die.exn;
      backtrace = Option.map Printexc.raw_backtrace_to_string die.backtrace;
      span_name = die.span_name;
      annotations = die.annotations;
    }

  let rec of_cause :
      type err (portable_err : value mod portable).
      (err -> portable_err) -> err same_domain_t -> portable_err t =
   fun convert -> function
    | Fail err -> Fail (convert err)
    | Die die -> Die (die_of_cause die)
    | Interrupt id -> Interrupt id
    | Sequential causes -> Sequential (List.map (of_cause convert) causes)
    | Concurrent causes -> Concurrent (List.map (of_cause convert) causes)
    | Finalizer cause -> Finalizer (Finalizer.of_finalizer cause)
    | Suppressed { primary; finalizer } ->
        Suppressed
          {
            primary = of_cause convert primary;
            finalizer = Finalizer.of_finalizer finalizer;
          }

  let equal_die left right =
    String.equal left.kind right.kind
    && String.equal left.message right.message
    && equal_option String.equal left.backtrace right.backtrace
    && equal_option String.equal left.span_name right.span_name
    && equal_list
         (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
         left.annotations right.annotations

  let rec equal equal_err left right =
    match (left, right) with
    | Fail a, Fail b -> equal_err a b
    | Die a, Die b -> equal_die a b
    | Interrupt a, Interrupt b -> equal_option Int.equal a b
    | Sequential a, Sequential b | Concurrent a, Concurrent b ->
        equal_list (equal equal_err) a b
    | Finalizer a, Finalizer b -> Finalizer.equal a b
    | Suppressed a, Suppressed b ->
        equal equal_err a.primary b.primary
        && Finalizer.equal a.finalizer b.finalizer
    | _ -> false

  let pp_backtrace fmt = function
    | None -> ()
    | Some bt -> Format.fprintf fmt "; backtrace=%S" bt

  let pp_die fmt die =
    Format.fprintf fmt "Die{kind=%S; message=%S" die.kind die.message;
    (match die.span_name with
    | None -> ()
    | Some name -> Format.fprintf fmt "; span_name=%S" name);
    (match die.annotations with
    | [] -> ()
    | annotations ->
        Format.fprintf fmt "; annotations=%a" pp_annotations annotations);
    pp_backtrace fmt die.backtrace;
    Format.pp_print_string fmt "}"

  let rec pp pp_err fmt = function
    | Fail err -> Format.fprintf fmt "Fail(%a)" pp_err err
    | Die die -> pp_die fmt die
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
    | Finalizer cause ->
        Format.fprintf fmt "Finalizer(%a)" Finalizer.pp cause
    | Suppressed { primary; finalizer } ->
        Format.fprintf fmt "Suppressed{primary=%a; finalizer=%a}" (pp pp_err)
          primary Finalizer.pp finalizer
end

let fail err = Fail err
let die_with_diagnostics ?backtrace ?span_name ?(annotations = []) exn =
  Die { exn; backtrace; span_name; annotations }

let die exn = die_with_diagnostics exn
let die_with_backtrace exn bt = die_with_diagnostics ~backtrace:bt exn
let interrupt = Interrupt None
let interrupt_with_id id = Interrupt (Some id)

let sequential = function
  | [] -> invalid_arg "Cause.sequential: empty"
  | [ one ] -> one
  | causes -> Sequential causes

let concurrent = function
  | [] -> invalid_arg "Cause.concurrent: empty"
  | [ one ] -> one
  | causes -> Concurrent causes

let finalizer = function
  | Finalizer.Finalizer inner -> Finalizer inner
  | cause -> Finalizer cause

let suppressed ~primary ~finalizer = Suppressed { primary; finalizer }
let to_portable = Portable.of_cause

let rec finalizer_of_cause :
    type err. (err -> string) -> err t -> Finalizer.t =
 fun render -> function
  | Fail err -> Finalizer.Fail (render err)
  | Die die -> Finalizer.Die die
  | Interrupt id -> Finalizer.Interrupt id
  | Sequential causes -> Finalizer.Sequential (List.map (finalizer_of_cause render) causes)
  | Concurrent causes -> Finalizer.Concurrent (List.map (finalizer_of_cause render) causes)
  | Finalizer cause -> Finalizer.Finalizer cause
  | Suppressed { primary; finalizer } ->
      Finalizer.Suppressed
        { primary = finalizer_of_cause render primary; finalizer }

let rec map : type err mapped. (err -> mapped) -> err t -> mapped t =
 fun f -> function
  | Fail err -> Fail (f err)
  | Die die -> Die die
  | Interrupt id -> Interrupt id
  | Sequential causes -> Sequential (List.map (map f) causes)
  | Concurrent causes -> Concurrent (List.map (map f) causes)
  | Finalizer cause -> Finalizer cause
  | Suppressed { primary; finalizer } ->
      Suppressed { primary = map f primary; finalizer }

let rec is_interrupt_only : type err. err t -> bool = function
  | Interrupt _ -> true
  | Sequential causes | Concurrent causes -> List.for_all is_interrupt_only causes
  | Finalizer cause -> Finalizer.is_interrupt_only cause
  | Suppressed { primary; finalizer } ->
      is_interrupt_only primary && Finalizer.is_interrupt_only finalizer
  | Fail _ | Die _ -> false

let rec equal : type err. (err -> err -> bool) -> err t -> err t -> bool =
 fun equal_err left right ->
  match (left, right) with
  | Fail a, Fail b -> equal_err a b
  | Die a, Die b -> equal_die a b
  | Interrupt a, Interrupt b -> equal_option Int.equal a b
  | Sequential a, Sequential b | Concurrent a, Concurrent b ->
      equal_list (equal equal_err) a b
  | Finalizer a, Finalizer b -> Finalizer.equal a b
  | Suppressed a, Suppressed b ->
      equal equal_err a.primary b.primary
      && Finalizer.equal a.finalizer b.finalizer
  | _ -> false

let rec diagnostic_equal :
    type err. (err -> err -> bool) -> err t -> err t -> bool =
 fun equal_err left right ->
  match (left, right) with
  | Fail a, Fail b -> equal_err a b
  | Die a, Die b -> diagnostic_equal_die a b
  | Interrupt a, Interrupt b -> equal_option Int.equal a b
  | Sequential a, Sequential b | Concurrent a, Concurrent b ->
      equal_list (diagnostic_equal equal_err) a b
  | Finalizer a, Finalizer b -> Finalizer.diagnostic_equal a b
  | Suppressed a, Suppressed b ->
      diagnostic_equal equal_err a.primary b.primary
      && Finalizer.diagnostic_equal a.finalizer b.finalizer
  | _ -> false

let rec pp :
    type err. (Format.formatter -> err -> unit) -> Format.formatter -> err t -> unit
    =
 fun pp_err fmt -> function
  | Fail err -> Format.fprintf fmt "Fail(%a)" pp_err err
  | Die die -> pp_die fmt die
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
  | Finalizer cause ->
      Format.fprintf fmt "Finalizer(%a)" Finalizer.pp cause
  | Suppressed { primary; finalizer } ->
      Format.fprintf fmt "Suppressed{primary=%a; finalizer=%a}" (pp pp_err)
        primary Finalizer.pp finalizer
