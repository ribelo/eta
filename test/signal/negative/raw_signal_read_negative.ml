module Signal = Eta_signal.Make_no_error ()

let source = Signal.Var.create 1
let signal = Signal.Var.watch source |> Signal.map (fun value -> value + 1)
let _must_not_typecheck = Signal.read signal
