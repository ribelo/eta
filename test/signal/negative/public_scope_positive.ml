module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let _ok =
  Signal.bind (Signal.const true) (fun active ->
      if active then Signal.const 1 else Signal.const 0)
