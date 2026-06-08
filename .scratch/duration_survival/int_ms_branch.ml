module Int_ms = struct
  type t = int

  let clamp n = if n < 0 then 0 else n
  let ms n = clamp n
  let seconds n = ms (n * 1_000)
  let zero = 0
  let add a b = ms (a + b)
  let scale t f = ms (int_of_float (float_of_int t *. max 0.0 f))
  let min = Int.min
  let max = Int.max
end

module Schedule = struct
  type t =
    | Recurs of int
    | Spaced of int
    | Exponential of int * float
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
    | Recurs n -> if step < n then Some Int_ms.zero else None
    | Spaced d -> Some d
    | Exponential (d, factor) -> Some (Int_ms.scale d (pow factor step))
    | Both (a, b) -> (
        match next_delay a ~step, next_delay b ~step with
        | Some da, Some db -> Some (Int_ms.max da db)
        | _ -> None)
    | Either (a, b) -> (
        match next_delay a ~step, next_delay b ~step with
        | Some da, Some db -> Some (Int_ms.min da db)
        | Some d, None | None, Some d -> Some d
        | None, None -> None)
end

let delay (_ms : int) value = value
let retry_after (_ : Schedule.t) value = value

(* This compiles in the int_ms branch but would be a type error with Duration.t:
   [delay 3 "value"]. The integer carries no unit at the type boundary. *)
let accepts_bare_int = delay 3 "value"
