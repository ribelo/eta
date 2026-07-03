module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let source = Signal.Var.create 1
let signal = Signal.Var.watch source

let _ok =
  Signal.map9
    (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
    signal signal signal signal signal signal signal signal signal
