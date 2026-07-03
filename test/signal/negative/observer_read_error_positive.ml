module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let _read
    (observer : int Signal.Observer.t) :
    (int, Signal.observer_read_error) Eta.Effect.t =
  Signal.Observer.read observer
