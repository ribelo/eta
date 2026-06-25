module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module A = Eta_signal.Make (Observer_error) ()
module B = Eta_signal.Make (Observer_error) ()

let source = A.Var.create 1
let signal = A.Var.watch source
let _must_not_typecheck = B.map (fun value -> value + 1) signal
