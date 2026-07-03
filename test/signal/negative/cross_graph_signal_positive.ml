module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module A = Eta_signal.Make (Observer_error) ()
module B = Eta_signal.Make (Observer_error) ()

let a_source = A.Var.create 1
let b_source = B.Var.create 1
let _a_ok = A.Var.watch a_source |> A.map (fun value -> value + 1)
let _b_ok = B.Var.watch b_source |> B.map (fun value -> value + 1)
