type t =
  | Recurs of int
  | Forever
  | Spaced of Duration.t
  | Fixed of Duration.t
  | Exponential of Duration.t * float
  | Fibonacci of Duration.t
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
let fibonacci initial = Fibonacci initial
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
  | Fibonacci d -> Format.fprintf ppf "Fibonacci(%a)" Duration.pp d
  | Linear { initial; step } ->
      Format.fprintf ppf "Linear(%a, %a)" Duration.pp initial Duration.pp step
  | Both (a, b) -> Format.fprintf ppf "Both(%a,%a)" pp a pp b
  | Either (a, b) -> Format.fprintf ppf "Either(%a,%a)" pp a pp b
  | And_then (a, b) -> Format.fprintf ppf "AndThen(%a,%a)" pp a pp b
  | Jittered (s, lo, hi) -> Format.fprintf ppf "Jittered(%a,%g,%g)" pp s lo hi
  | Named (s, n) -> Format.fprintf ppf "Named(%a, %S)" pp s n

let pow_factor f step = f ** float_of_int step

let scale_capped d factor =
  let factor = if factor < 0.0 then 0.0 else factor in
  let scaled = float_of_int (Duration.to_ms d) *. factor in
  match classify_float scaled with
  | FP_nan -> invalid_arg "Duration.scale"
  | FP_infinite -> Duration.ms max_int
  | FP_normal | FP_subnormal | FP_zero ->
      if scaled >= float_of_int max_int then Duration.ms max_int
      else Duration.scale d factor

let add_capped a b =
  let a_ms = Duration.to_ms a in
  let b_ms = Duration.to_ms b in
  if a_ms > max_int - b_ms then Duration.ms max_int
  else Duration.ms (a_ms + b_ms)

let default_random = lazy (Capabilities.random_default ())

type state =
  | Driver_recurs of int
  | Driver_forever
  | Driver_spaced of Duration.t
  | Driver_fixed of Duration.t
  | Driver_exponential of Duration.t * float * int
  | Driver_fibonacci of {
      previous : Duration.t;
      current : Duration.t;
    }
  | Driver_linear of {
      initial : Duration.t;
      step : Duration.t;
      index : int;
    }
  | Driver_both of state * state
  | Driver_either of state * state
  | Driver_and_then of state * t
  | Driver_jittered of state * float * float
  | Driver_named of state

type driver = {
  random : Capabilities.random;
  state : state;
}

let rec state_of_schedule = function
  | Recurs n -> Driver_recurs n
  | Forever -> Driver_forever
  | Spaced d -> Driver_spaced d
  | Fixed d -> Driver_fixed d
  | Exponential (d, factor) -> Driver_exponential (d, factor, 0)
  | Fibonacci d -> Driver_fibonacci { previous = Duration.zero; current = d }
  | Linear { initial; step } -> Driver_linear { initial; step; index = 0 }
  | Both (a, b) -> Driver_both (state_of_schedule a, state_of_schedule b)
  | Either (a, b) -> Driver_either (state_of_schedule a, state_of_schedule b)
  | And_then (a, b) -> Driver_and_then (state_of_schedule a, b)
  | Jittered (inner, lo, hi) ->
      Driver_jittered (state_of_schedule inner, lo, hi)
  | Named (inner, _) -> Driver_named (state_of_schedule inner)

let start ?(random = Lazy.force default_random) schedule =
  { random; state = state_of_schedule schedule }

let rec next_state random = function
  | Driver_recurs remaining ->
      if remaining > 0 then Some (Duration.zero, Driver_recurs (remaining - 1))
      else None
  | Driver_forever -> Some (Duration.zero, Driver_forever)
  | Driver_spaced d -> Some (d, Driver_spaced d)
  | Driver_fixed d -> Some (d, Driver_fixed d)
  | Driver_exponential (d, factor, step) ->
      Some
        ( scale_capped d (pow_factor factor step),
          Driver_exponential (d, factor, step + 1) )
  | Driver_fibonacci { previous; current } ->
      let next = add_capped previous current in
      Some (current, Driver_fibonacci { previous = current; current = next })
  | Driver_linear { initial; step; index } ->
      let delta = scale_capped step (float_of_int index) in
      Some
        ( add_capped initial delta,
          Driver_linear { initial; step; index = index + 1 } )
  | Driver_both (a, b) -> (
      match next_state random a, next_state random b with
      | Some (da, a'), Some (db, b') ->
          Some (Duration.max da db, Driver_both (a', b'))
      | _ -> None)
  | Driver_either (a, b) -> (
      match next_state random a, next_state random b with
      | Some (da, a'), Some (db, b') ->
          Some (Duration.min da db, Driver_either (a', b'))
      | Some (d, a'), None -> Some (d, a')
      | None, Some (d, b') -> Some (d, b')
      | None, None -> None)
  | Driver_and_then (a, b) -> (
      match next_state random a with
      | Some (d, a') -> Some (d, Driver_and_then (a', b))
      | None -> next_state random (state_of_schedule b))
  | Driver_jittered (inner, lo, hi) -> (
      match next_state random inner with
      | None -> None
      | Some (d, inner') ->
          let factor =
            lo +. ((hi -. lo) *. Capabilities.random_float random 1.0)
          in
          Some (scale_capped d factor, Driver_jittered (inner', lo, hi)))
  | Driver_named inner -> (
      match next_state random inner with
      | None -> None
      | Some (d, inner') -> Some (d, Driver_named inner'))

let next driver =
  match next_state driver.random driver.state with
  | None -> None
  | Some (delay, state) -> Some (delay, { driver with state })

let next_delay ?random sch ~step =
  let rec advance driver remaining =
    match next driver with
    | None -> None
    | Some (delay, driver') ->
        if remaining <= 0 then Some delay else advance driver' (remaining - 1)
  in
  advance (start ?random sch) step
