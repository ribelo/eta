module Observer_error = struct
  type t = unit

  let pp ppf () = Format.pp_print_string ppf "()"
end

module Signal = Eta_signal.Make (Observer_error) ()

let _must_not_typecheck = Signal.Private_test_hooks.clear ()
