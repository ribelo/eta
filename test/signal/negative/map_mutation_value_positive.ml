module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let source = Signal.Var.create 1
let signal = Signal.Var.watch source

let _mapped : int Signal.signal =
  Signal.map (fun value -> value + 1) signal

let _mutation_effect () = Signal.Var.set source 2
