type t : immutable_data =
  | Recurs of int
  | Forever
  | Spaced of Duration.t
  | Fixed of Duration.t
  | Exponential of Duration.t * float
  | Linear of { initial : Duration.t; step : Duration.t }
  | Both of t * t
  | Either of t * t
  | And_then of t * t
  | Jittered of t * float * float
  | Named of t * string

let recurs n = Recurs (max 0 n)
let forever = Forever
let spaced d = Spaced d
let fixed d = Fixed d
let exponential ?(factor = 2.0) initial = Exponential (initial, factor)
let linear ~initial ~step = Linear { initial; step }
let both a b = Both (a, b)
let either a b = Either (a, b)
let and_then a b = And_then (a, b)
let jittered ?(min = 0.8) ?(max = 1.2) self =
  let lo = if min < 0.0 then 0.0 else min in
  let hi = if max < lo then lo else max in
  Jittered (self, lo, hi)
let named name s = Named (s, name)

let rec pp ppf = function
  | Recurs n -> Format.fprintf ppf "Recurs(%d)" n
  | Forever -> Format.fprintf ppf "Forever"
  | Spaced d -> Format.fprintf ppf "Spaced(%a)" Duration.pp d
  | Fixed d -> Format.fprintf ppf "Fixed(%a)" Duration.pp d
  | Exponential (d, f) -> Format.fprintf ppf "Exponential(%a, %g)" Duration.pp d f
  | Linear { initial; step } ->
      Format.fprintf ppf "Linear(%a, %a)" Duration.pp initial Duration.pp step
  | Both (a, b) -> Format.fprintf ppf "Both(%a,%a)" pp a pp b
  | Either (a, b) -> Format.fprintf ppf "Either(%a,%a)" pp a pp b
  | And_then (a, b) -> Format.fprintf ppf "AndThen(%a,%a)" pp a pp b
  | Jittered (s, lo, hi) -> Format.fprintf ppf "Jittered(%a,%g,%g)" pp s lo hi
  | Named (s, n) -> Format.fprintf ppf "Named(%a, %S)" pp s n

let pow_factor f step =
  let v = ref 1.0 in
  for _ = 0 to step - 1 do v := !v *. f done;
  !v

let rec next_delay sch ~step =
  match sch with
  | Recurs n -> if step < n then Some Duration.zero else None
  | Forever -> Some Duration.zero
  | Spaced d | Fixed d -> Some d
  | Exponential (d, f) -> Some (Duration.scale d (pow_factor f step))
  | Linear { initial; step = s } ->
      Some (Duration.add initial (Duration.scale s (float_of_int step)))
  | Both (a, b) -> (
      match next_delay a ~step, next_delay b ~step with
      | Some da, Some db -> Some (Duration.max da db)
      | _ -> None)
  | Either (a, b) -> (
      match next_delay a ~step, next_delay b ~step with
      | Some da, Some db -> Some (Duration.min da db)
      | Some d, None | None, Some d -> Some d
      | None, None -> None)
  | And_then (a, b) -> (
      match next_delay a ~step with Some d -> Some d | None -> next_delay b ~step)
  | Jittered (inner, lo, hi) -> (
      match next_delay inner ~step with
      | None -> None
      | Some d ->
          let factor = lo +. ((hi -. lo) *. Random.float 1.0) in
          Some (Duration.scale d factor))
  | Named (s, _) -> next_delay s ~step
