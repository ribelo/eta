module Observer_error = struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end

module Signal = Eta_signal.Make (Observer_error) ()

let _must_not_typecheck : int Signal.signal =
  Signal.Time.now ~every:(Eta.Duration.ms 1) ()
