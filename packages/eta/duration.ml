type t : immutable_data = { ms : int }

let zero = { ms = 0 }
let clamp_nonnegative n = if n < 0 then 0 else n
let checked_mul name n factor =
  if n <= 0 then 0
  else if n > max_int / factor then invalid_arg name
  else n * factor

let checked_add name a b =
  if a > max_int - b then invalid_arg name else a + b

let ms n = { ms = clamp_nonnegative n }
let seconds n = { ms = checked_mul "Duration.seconds" n 1_000 }
let minutes n = { ms = checked_mul "Duration.minutes" n 60_000 }
let hours n = { ms = checked_mul "Duration.hours" n 3_600_000 }
let days n = { ms = checked_mul "Duration.days" n 86_400_000 }
let weeks n = { ms = checked_mul "Duration.weeks" n 604_800_000 }
let to_ms t = t.ms
let to_seconds_float t = float_of_int t.ms /. 1000.0
let is_zero t = t.ms = 0
let add a b = { ms = checked_add "Duration.add" a.ms b.ms }
let ( + ) = add
let subtract a b = ms (a.ms - b.ms)
let times t n =
  if n <= 0 then zero
  else if t.ms > max_int / n then invalid_arg "Duration.times"
  else { ms = t.ms * n }

let divide t by = if by = 0 then None else Some (ms (t.ms / by))
let min a b = if a.ms <= b.ms then a else b
let max a b = if a.ms >= b.ms then a else b
let clamp ~min:min_ ~max:max_ t = t |> max min_ |> min max_
let between ~min:min_ ~max:max_ t = min_.ms <= t.ms && t.ms <= max_.ms
let compare a b = Int.compare a.ms b.ms
let scale t f =
  let f = if f < 0.0 then 0.0 else f in
  let scaled = float_of_int t.ms *. f in
  if Float.is_nan scaled || scaled > float_of_int max_int then
    invalid_arg "Duration.scale"
  else { ms = clamp_nonnegative (int_of_float scaled) }
let pp ppf t = Format.fprintf ppf "%dms" t.ms
let equal a b = a.ms = b.ms
