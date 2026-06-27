module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let source = Signal.Var.create 1
let signal = Signal.Var.watch source

let _must_not_typecheck : int Signal.signal =
  Signal.map
    (fun value ->
      Signal.Var.set source (value + 1))
    signal
