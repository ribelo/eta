type interrupt_id : immutable_data = int

type die = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
  span_name : string option;
  annotations : (string * string) list;
}

type 'err t =
  | Fail of 'err
  | Die of die
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Suppressed of { primary : 'err t; finalizer : 'err t }

type 'err same_domain_t = 'err t

type ('err, 'die, 'cause) tree_view =
  | VFail of 'err
  | VDie of 'die
  | VInterrupt of interrupt_id option
  | VSequential of 'cause list
  | VConcurrent of 'cause list
  | VSuppressed of 'cause * 'cause

let equal_option equal_a left right =
  match (left, right) with
  | None, None -> true
  | Some a, Some b -> equal_a a b
  | _ -> false

let equal_list equal_a left right =
  List.length left = List.length right && List.for_all2 equal_a left right

let rec equal_tree view ~equal_err ~equal_die left right =
  match (view left, view right) with
  | VFail a, VFail b -> equal_err a b
  | VDie a, VDie b -> equal_die a b
  | VInterrupt a, VInterrupt b -> equal_option Int.equal a b
  | VSequential a, VSequential b | VConcurrent a, VConcurrent b ->
      equal_list (equal_tree view ~equal_err ~equal_die) a b
  | VSuppressed (primary_a, finalizer_a), VSuppressed (primary_b, finalizer_b) ->
      equal_tree view ~equal_err ~equal_die primary_a primary_b
      && equal_tree view ~equal_err ~equal_die finalizer_a finalizer_b
  | _ -> false

let pp_annotations fmt annotations =
  Format.fprintf fmt "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
       (fun fmt (key, value) -> Format.fprintf fmt "%s=%S" key value))
    annotations

let rec pp_tree view ~pp_err ~pp_die fmt cause =
  match view cause with
  | VFail err -> Format.fprintf fmt "Fail(%a)" pp_err err
  | VDie die -> pp_die fmt die
  | VInterrupt None -> Format.pp_print_string fmt "Interrupt"
  | VInterrupt (Some id) -> Format.fprintf fmt "Interrupt(%d)" id
  | VSequential causes ->
      Format.fprintf fmt "Sequential[%a]"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
           (pp_tree view ~pp_err ~pp_die))
        causes
  | VConcurrent causes ->
      Format.fprintf fmt "Concurrent[%a]"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
           (pp_tree view ~pp_err ~pp_die))
        causes
  | VSuppressed (primary, finalizer) ->
      Format.fprintf fmt "Suppressed{primary=%a; finalizer=%a}"
        (pp_tree view ~pp_err ~pp_die)
        primary
        (pp_tree view ~pp_err ~pp_die)
        finalizer

module Portable = struct
  type die : value mod portable = {
    kind : string;
    message : string;
    backtrace : string option;
    span_name : string option;
    annotations : (string * string) list;
  }

  type ('err : value mod portable) t : value mod portable =
    | Fail of 'err
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Suppressed of { primary : 'err t; finalizer : 'err t }

  let rec of_cause :
      type err (portable_err : value mod portable).
      (err -> portable_err) -> err same_domain_t -> portable_err t =
   fun convert -> function
    | Fail err -> Fail (convert err)
    | Die die ->
        Die
          {
            kind = Printexc.exn_slot_name die.exn;
            message = Printexc.to_string die.exn;
            backtrace = Option.map Printexc.raw_backtrace_to_string die.backtrace;
            span_name = die.span_name;
            annotations = die.annotations;
          }
    | Interrupt id -> Interrupt id
    | Sequential causes -> Sequential (List.map (of_cause convert) causes)
    | Concurrent causes -> Concurrent (List.map (of_cause convert) causes)
    | Suppressed { primary; finalizer } ->
        Suppressed
          {
            primary = of_cause convert primary;
            finalizer = of_cause convert finalizer;
          }

  let equal_die left right =
    String.equal left.kind right.kind
    && String.equal left.message right.message
    && equal_option String.equal left.backtrace right.backtrace
    && equal_option String.equal left.span_name right.span_name
    && equal_list
         (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
         left.annotations right.annotations

  let view = function
    | Fail err -> VFail err
    | Die die -> VDie die
    | Interrupt id -> VInterrupt id
    | Sequential causes -> VSequential causes
    | Concurrent causes -> VConcurrent causes
    | Suppressed { primary; finalizer } -> VSuppressed (primary, finalizer)

  let equal equal_err = equal_tree view ~equal_err ~equal_die

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

  let pp pp_err = pp_tree view ~pp_err ~pp_die
end

let fail err = Fail err
let die_with_diagnostics ?backtrace ?span_name ?(annotations = []) exn =
  Die { exn; backtrace; span_name; annotations }

let die exn = die_with_diagnostics exn
let die_with_backtrace exn bt = die_with_diagnostics ~backtrace:bt exn
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
let to_portable = Portable.of_cause

let rec is_interrupt_only = function
  | Interrupt _ -> true
  | Sequential causes | Concurrent causes -> List.for_all is_interrupt_only causes
  | Suppressed { primary; finalizer } ->
      is_interrupt_only primary && is_interrupt_only finalizer
  | Fail _ | Die _ -> false

let view = function
  | Fail err -> VFail err
  | Die die -> VDie die
  | Interrupt id -> VInterrupt id
  | Sequential causes -> VSequential causes
  | Concurrent causes -> VConcurrent causes
  | Suppressed { primary; finalizer } -> VSuppressed (primary, finalizer)

let equal_die left right =
  left.exn == right.exn
  && equal_option String.equal left.span_name right.span_name
  && equal_list
       (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
       left.annotations right.annotations

let equal equal_err = equal_tree view ~equal_err ~equal_die

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

let pp pp_err = pp_tree view ~pp_err ~pp_die
