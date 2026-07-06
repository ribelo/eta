module A = Eta_signal.Make_no_error ()
module B = Eta_signal.Make_no_error ()

let source = A.Var.create 1
let signal = A.Var.watch source
let _must_not_typecheck = B.map (fun value -> value + 1) signal
