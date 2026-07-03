module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let _dispose_observer (observer : int Signal.Observer.t) =
  Signal.Observer.dispose observer
