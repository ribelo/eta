type t = { ms : int }

let zero = { ms = 0 }
let clamp_nonnegative n = if n < 0 then 0 else n
let ms n = { ms = clamp_nonnegative n }
let seconds n = ms (n * 1_000)
let minutes n = ms (n * 60_000)
let hours n = ms (n * 3_600_000)
let days n = ms (n * 86_400_000)
let weeks n = days (n * 7)
let to_ms t = t.ms
let to_seconds_float t = float_of_int t.ms /. 1000.0
let is_zero t = t.ms = 0
let add a b = { ms = a.ms + b.ms }
let ( + ) = add
let subtract a b = ms (a.ms - b.ms)
let times t n = ms (t.ms * n)
let divide t by = if by = 0 then None else Some (ms (t.ms / by))
let min a b = if a.ms <= b.ms then a else b
let max a b = if a.ms >= b.ms then a else b
let clamp ~min:min_ ~max:max_ t = t |> max min_ |> min max_
let between ~min:min_ ~max:max_ t = min_.ms <= t.ms && t.ms <= max_.ms
let compare a b = Int.compare a.ms b.ms
let scale t f =
  let f = if f < 0.0 then 0.0 else f in
  { ms = clamp_nonnegative (int_of_float (float_of_int t.ms *. f)) }
let pp ppf t = Format.fprintf ppf "%dms" t.ms
let equal a b = a.ms = b.ms
