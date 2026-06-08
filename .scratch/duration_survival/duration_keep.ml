module Duration = struct
  type t = { ms : int }

  let clamp n = if n < 0 then 0 else n
  let ms n = { ms = clamp n }
  let seconds n = ms (n * 1_000)
  let zero = ms 0
  let to_ms t = t.ms
  let add a b = ms (a.ms + b.ms)
  let scale t f = ms (int_of_float (float_of_int t.ms *. max 0.0 f))
  let min a b = if a.ms <= b.ms then a else b
  let max a b = if a.ms >= b.ms then a else b
end

module Schedule = struct
  type t =
    | Recurs of int
    | Spaced of Duration.t
    | Exponential of Duration.t * float
    | Both of t * t
    | Either of t * t

  let recurs n = Recurs n
  let spaced d = Spaced d
  let exponential ?(factor = 2.0) d = Exponential (d, factor)
  let both a b = Both (a, b)
  let either a b = Either (a, b)

  let pow factor step = factor ** float_of_int step

  let rec next_delay t ~step =
    match t with
    | Recurs n -> if step < n then Some Duration.zero else None
    | Spaced d -> Some d
    | Exponential (d, factor) -> Some (Duration.scale d (pow factor step))
    | Both (a, b) -> (
        match next_delay a ~step, next_delay b ~step with
        | Some da, Some db -> Some (Duration.max da db)
        | _ -> None)
    | Either (a, b) -> (
        match next_delay a ~step, next_delay b ~step with
        | Some da, Some db -> Some (Duration.min da db)
        | Some d, None | None, Some d -> Some d
        | None, None -> None)
end

let delay (_ : Duration.t) value = value
let retry_after (_ : Schedule.t) value = value
