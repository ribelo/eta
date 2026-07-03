module Observer_error = struct
  type t = unit

  let pp ppf () = Format.pp_print_string ppf "()"
end

module Signal = Eta_signal.Make (Observer_error) ()

let _ok = Signal.stats ()
