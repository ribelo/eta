type interrupt_id = int

type die = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
  span_name : string option;
  annotations : (string * string) list;
}

let[@inline always] equal_annotations left right =
  List.equal
    (fun (ak, av) (bk, bv) -> String.equal ak bk && String.equal av bv)
    left right

let equal_die left right =
  left.exn == right.exn
  && Option.equal String.equal left.span_name right.span_name
  && equal_annotations left.annotations right.annotations

let backtrace_string die = Option.map Printexc.raw_backtrace_to_string die.backtrace

let diagnostic_equal_die left right =
  String.equal (Printexc.exn_slot_name left.exn)
    (Printexc.exn_slot_name right.exn)
  && String.equal (Printexc.to_string left.exn) (Printexc.to_string right.exn)
  && Option.equal String.equal (backtrace_string left) (backtrace_string right)
  && Option.equal String.equal left.span_name right.span_name
  && equal_annotations left.annotations right.annotations

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

let pp_die_metadata fmt span_name annotations =
  (match span_name with
  | None -> ()
  | Some name -> Format.fprintf fmt "; span_name=%S" name);
  match annotations with
  | [] -> ()
  | annotations ->
      Format.fprintf fmt "; annotations=%a" pp_annotations annotations

let pp_die fmt die =
  Format.fprintf fmt "Die{exn=%S" (Printexc.to_string die.exn);
  pp_die_metadata fmt die.span_name die.annotations;
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
    | Interrupt a, Interrupt b -> Option.equal Int.equal a b
    | Sequential a, Sequential b | Concurrent a, Concurrent b ->
        List.equal equal a b
    | Finalizer a, Finalizer b -> equal a b
    | Suppressed a, Suppressed b ->
        equal a.primary b.primary && equal a.finalizer b.finalizer
    | _ -> false

  let rec diagnostic_equal left right =
    match (left, right) with
    | Fail a, Fail b -> String.equal a b
    | Die a, Die b -> diagnostic_equal_die a b
    | Interrupt a, Interrupt b -> Option.equal Int.equal a b
    | Sequential a, Sequential b | Concurrent a, Concurrent b ->
        List.equal diagnostic_equal a b
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
  type die = {
    kind : string;
    message : string;
    backtrace : string option;
    span_name : string option;
    annotations : (string * string) list;
  }

  let die_of_cause die =
    {
      kind = Printexc.exn_slot_name die.exn;
      message = Printexc.to_string die.exn;
      backtrace = Option.map Printexc.raw_backtrace_to_string die.backtrace;
      span_name = die.span_name;
      annotations = die.annotations;
    }

  let equal_die left right =
    String.equal left.kind right.kind
    && String.equal left.message right.message
    && Option.equal String.equal left.backtrace right.backtrace
    && Option.equal String.equal left.span_name right.span_name
    && equal_annotations left.annotations right.annotations

  let pp_backtrace fmt = function
    | None -> ()
    | Some bt -> Format.fprintf fmt "; backtrace=%S" bt

  let pp_die fmt die =
    Format.fprintf fmt "Die{kind=%S; message=%S" die.kind die.message;
    pp_die_metadata fmt die.span_name die.annotations;
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

    let rec equal left right =
      match (left, right) with
      | Fail a, Fail b -> String.equal a b
      | Die a, Die b -> equal_die a b
      | Interrupt a, Interrupt b -> Option.equal Int.equal a b
      | Sequential a, Sequential b | Concurrent a, Concurrent b ->
          List.equal equal a b
      | Finalizer a, Finalizer b -> equal a b
      | Suppressed a, Suppressed b ->
          equal a.primary b.primary && equal a.finalizer b.finalizer
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
  end

  type ('err) t =
    | Fail of 'err
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Finalizer of Finalizer.t
    | Suppressed of { primary : 'err t; finalizer : Finalizer.t }

  let rec of_cause :
      type err portable_err.
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

  let rec equal (equal_err) left right =
    match (left, right) with
    | Fail a, Fail b -> equal_err a b
    | Die a, Die b -> equal_die a b
    | Interrupt a, Interrupt b -> Option.equal Int.equal a b
    | Sequential a, Sequential b | Concurrent a, Concurrent b ->
        List.equal (equal equal_err) a b
    | Finalizer a, Finalizer b -> Finalizer.equal a b
    | Suppressed a, Suppressed b ->
        equal equal_err a.primary b.primary
        && Finalizer.equal a.finalizer b.finalizer
    | _ -> false

  let rec pp (pp_err) fmt = function
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
let interrupt_id_counter = Atomic.make 0
let fresh_interrupt_id () = Atomic.fetch_and_add interrupt_id_counter 1 + 1
let equal_interrupt_id a b = Int.equal a b
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
 fun (render) -> function
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
 fun (f) -> function
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

let failures cause =
  let rec collect acc = function
    | Fail err -> err :: acc
    | Die _ | Interrupt _ | Finalizer _ -> acc
    | Sequential causes | Concurrent causes -> List.fold_left collect acc causes
    | Suppressed { primary; finalizer = _ } -> collect acc primary
  in
  List.rev (collect [] cause)

let defects cause =
  let rec collect_finalizer acc = function
    | Finalizer.Fail _ | Finalizer.Interrupt _ -> acc
    | Finalizer.Die die -> die :: acc
    | Finalizer.Sequential causes | Finalizer.Concurrent causes ->
        List.fold_left collect_finalizer acc causes
    | Finalizer.Finalizer cause -> collect_finalizer acc cause
    | Finalizer.Suppressed { primary; finalizer } ->
        collect_finalizer (collect_finalizer acc primary) finalizer
  in
  let rec collect acc = function
    | Fail _ | Interrupt _ -> acc
    | Die die -> die :: acc
    | Sequential causes | Concurrent causes -> List.fold_left collect acc causes
    | Finalizer cause -> collect_finalizer acc cause
    | Suppressed { primary; finalizer } ->
        collect_finalizer (collect acc primary) finalizer
  in
  List.rev (collect [] cause)

let interruptors cause =
  let add id acc =
    if List.exists (equal_interrupt_id id) acc then acc else id :: acc
  in
  let add_opt id acc = match id with None -> acc | Some id -> add id acc in
  let rec collect_finalizer acc = function
    | Finalizer.Fail _ | Finalizer.Die _ -> acc
    | Finalizer.Interrupt id -> add_opt id acc
    | Finalizer.Sequential causes | Finalizer.Concurrent causes ->
        List.fold_left collect_finalizer acc causes
    | Finalizer.Finalizer cause -> collect_finalizer acc cause
    | Finalizer.Suppressed { primary; finalizer } ->
        collect_finalizer (collect_finalizer acc primary) finalizer
  in
  let rec collect acc = function
    | Fail _ | Die _ -> acc
    | Interrupt id -> add_opt id acc
    | Sequential causes | Concurrent causes -> List.fold_left collect acc causes
    | Finalizer cause -> collect_finalizer acc cause
    | Suppressed { primary; finalizer } ->
        collect_finalizer (collect acc primary) finalizer
  in
  List.rev (collect [] cause)

let finalizer_failures cause =
  let rec collect_finalizer acc = function
    | Finalizer.Fail msg -> msg :: acc
    | Finalizer.Die _ | Finalizer.Interrupt _ -> acc
    | Finalizer.Sequential causes | Finalizer.Concurrent causes ->
        List.fold_left collect_finalizer acc causes
    | Finalizer.Finalizer cause -> collect_finalizer acc cause
    | Finalizer.Suppressed { primary; finalizer } ->
        collect_finalizer (collect_finalizer acc primary) finalizer
  in
  let rec collect acc = function
    | Fail _ | Die _ | Interrupt _ -> acc
    | Sequential causes | Concurrent causes -> List.fold_left collect acc causes
    | Finalizer cause -> collect_finalizer acc cause
    | Suppressed { primary; finalizer } ->
        collect_finalizer (collect acc primary) finalizer
  in
  List.rev (collect [] cause)

let squash render_error cause =
  match failures cause with
  | err :: _ -> render_error err
  | [] -> (
      match defects cause with
      | die :: _ -> die.exn
      | [] -> (
          match finalizer_failures cause with
          | msg :: _ -> Failure msg
          | [] -> Failure "All fibers interrupted without error"))

let rec equal : type err. (err -> err -> bool) -> err t -> err t -> bool =
 fun (equal_err) left right ->
  match (left, right) with
  | Fail a, Fail b -> equal_err a b
  | Die a, Die b -> equal_die a b
  | Interrupt a, Interrupt b -> Option.equal Int.equal a b
  | Sequential a, Sequential b | Concurrent a, Concurrent b ->
      List.equal (equal equal_err) a b
  | Finalizer a, Finalizer b -> Finalizer.equal a b
  | Suppressed a, Suppressed b ->
      equal equal_err a.primary b.primary
      && Finalizer.equal a.finalizer b.finalizer
  | _ -> false

let rec diagnostic_equal :
    type err. (err -> err -> bool) -> err t -> err t -> bool =
 fun (equal_err) left right ->
  match (left, right) with
  | Fail a, Fail b -> equal_err a b
  | Die a, Die b -> diagnostic_equal_die a b
  | Interrupt a, Interrupt b -> Option.equal Int.equal a b
  | Sequential a, Sequential b | Concurrent a, Concurrent b ->
      List.equal (diagnostic_equal equal_err) a b
  | Finalizer a, Finalizer b -> Finalizer.diagnostic_equal a b
  | Suppressed a, Suppressed b ->
      diagnostic_equal equal_err a.primary b.primary
      && Finalizer.diagnostic_equal a.finalizer b.finalizer
  | _ -> false

let rec pp :
    type err.
    (Format.formatter -> err -> unit) -> Format.formatter -> err t -> unit
    =
 fun (pp_err) fmt -> function
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

let pretty render_error cause =
  let buffer = Buffer.create 128 in
  let add_line indent text =
    Buffer.add_string buffer (String.make (indent * 2) ' ');
    Buffer.add_string buffer text;
    Buffer.add_char buffer '\n'
  in
  let add_annotations indent annotations =
    List.iter
      (fun (key, value) -> add_line indent ("annotation " ^ key ^ "=" ^ value))
      annotations
  in
  let add_backtrace indent = function
    | None -> ()
    | Some backtrace ->
        add_line indent "backtrace:";
        Printexc.raw_backtrace_to_string backtrace
        |> String.split_on_char '\n'
        |> List.iter (fun line ->
               if not (String.equal line "") then add_line (indent + 1) line)
  in
  let add_die indent die =
    add_line indent ("defect: " ^ Printexc.to_string die.exn);
    (match die.span_name with
    | None -> ()
    | Some name -> add_line (indent + 1) ("span: " ^ name));
    add_annotations (indent + 1) die.annotations;
    add_backtrace (indent + 1) die.backtrace
  in
  let rec add_finalizer indent = function
    | Finalizer.Fail msg -> add_line indent ("finalizer fail: " ^ msg)
    | Finalizer.Die die -> add_die indent die
    | Finalizer.Interrupt None -> add_line indent "interrupt"
    | Finalizer.Interrupt (Some id) ->
        add_line indent ("interrupt: " ^ string_of_int id)
    | Finalizer.Sequential causes ->
        add_line indent "sequential:";
        List.iter (add_finalizer (indent + 1)) causes
    | Finalizer.Concurrent causes ->
        add_line indent "concurrent:";
        List.iter (add_finalizer (indent + 1)) causes
    | Finalizer.Finalizer cause ->
        add_line indent "finalizer:";
        add_finalizer (indent + 1) cause
    | Finalizer.Suppressed { primary; finalizer } ->
        add_line indent "suppressed:";
        add_line (indent + 1) "primary:";
        add_finalizer (indent + 2) primary;
        add_line (indent + 1) "finalizer:";
        add_finalizer (indent + 2) finalizer
  in
  let rec add_cause indent = function
    | Fail err -> add_line indent ("fail: " ^ render_error err)
    | Die die -> add_die indent die
    | Interrupt None -> add_line indent "interrupt"
    | Interrupt (Some id) -> add_line indent ("interrupt: " ^ string_of_int id)
    | Sequential causes ->
        add_line indent "sequential:";
        List.iter (add_cause (indent + 1)) causes
    | Concurrent causes ->
        add_line indent "concurrent:";
        List.iter (add_cause (indent + 1)) causes
    | Finalizer cause ->
        add_line indent "finalizer:";
        add_finalizer (indent + 1) cause
    | Suppressed { primary; finalizer } ->
        add_line indent "suppressed:";
        add_line (indent + 1) "primary:";
        add_cause (indent + 2) primary;
        add_line (indent + 1) "finalizer:";
        add_finalizer (indent + 2) finalizer
  in
  add_cause 0 cause;
  let rendered = Buffer.contents buffer in
  let len = String.length rendered in
  if len > 0 && Char.equal rendered.[len - 1] '\n' then
    String.sub rendered 0 (len - 1)
  else rendered
