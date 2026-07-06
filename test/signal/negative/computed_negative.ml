module Signal = Eta_signal.Make_no_error ()

let source = Signal.Var.create 1
let _must_not_typecheck = Signal.computed (fun () -> Signal.Var.value source)
