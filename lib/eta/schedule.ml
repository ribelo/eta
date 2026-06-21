type t =
  | Recurs of int
  | Forever
  | Spaced of Duration.t
  | Fixed of Duration.t
  | Windowed of Duration.t
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
let windowed d = Windowed d
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
  | Windowed d -> Format.fprintf ppf "Windowed(%a)" Duration.pp d
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

let add_ms_capped a b = if a > max_int - b then max_int else a + b
let elapsed_since ~start now_ms = if now_ms <= start then 0 else now_ms - start

let default_random = lazy (Capabilities.random_default ())

type state =
  | Driver_recurs of int
  | Driver_forever
  | Driver_spaced of Duration.t
  | Driver_fixed of {
      interval : Duration.t;
      start_ms : int option;
      last_run_ms : int option;
    }
  | Driver_windowed of {
      interval : Duration.t;
      start_ms : int option;
    }
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
  | Fixed d -> Driver_fixed { interval = d; start_ms = None; last_run_ms = None }
  | Windowed d -> Driver_windowed { interval = d; start_ms = None }
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

let rec next_state random ~now_ms = function
  | Driver_recurs remaining ->
      if remaining > 0 then Some (Duration.zero, Driver_recurs (remaining - 1))
      else None
  | Driver_forever -> Some (Duration.zero, Driver_forever)
  | Driver_spaced d -> Some (d, Driver_spaced d)
  | Driver_fixed { interval; start_ms; last_run_ms } ->
      let interval_ms = Duration.to_ms interval in
      if interval_ms = 0 then
        Some
          ( Duration.zero,
            Driver_fixed { interval; start_ms; last_run_ms } )
      else (
        match (start_ms, last_run_ms) with
        | Some start_ms, Some last_run_ms ->
            let running_behind =
              now_ms > add_ms_capped last_run_ms interval_ms
            in
            let elapsed = elapsed_since ~start:start_ms now_ms in
            let boundary = interval_ms - (elapsed mod interval_ms) in
            let delay_ms =
              if running_behind then 0
              else if boundary = 0 then interval_ms
              else boundary
            in
            let next_run_ms =
              if running_behind then now_ms else add_ms_capped now_ms delay_ms
            in
            Some
              ( Duration.ms delay_ms,
                Driver_fixed
                  {
                    interval;
                    start_ms = Some start_ms;
                    last_run_ms = Some next_run_ms;
                  } )
        | _ ->
            Some
              ( interval,
                Driver_fixed
                  {
                    interval;
                    start_ms = Some now_ms;
                    last_run_ms = Some (add_ms_capped now_ms interval_ms);
                  } ))
  | Driver_windowed { interval; start_ms } ->
      let interval_ms = Duration.to_ms interval in
      if interval_ms = 0 then
        Some (Duration.zero, Driver_windowed { interval; start_ms })
      else (
        match start_ms with
        | None ->
            Some
              ( interval,
                Driver_windowed { interval; start_ms = Some now_ms } )
        | Some start_ms ->
            let elapsed = elapsed_since ~start:start_ms now_ms in
            let boundary = interval_ms - (elapsed mod interval_ms) in
            let delay_ms = if boundary = 0 then interval_ms else boundary in
            Some
              ( Duration.ms delay_ms,
                Driver_windowed { interval; start_ms = Some start_ms } ))
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
      match next_state random ~now_ms a, next_state random ~now_ms b with
      | Some (da, a'), Some (db, b') ->
          Some (Duration.max da db, Driver_both (a', b'))
      | _ -> None)
  | Driver_either (a, b) -> (
      match next_state random ~now_ms a, next_state random ~now_ms b with
      | Some (da, a'), Some (db, b') ->
          Some (Duration.min da db, Driver_either (a', b'))
      | Some (d, a'), None -> Some (d, a')
      | None, Some (d, b') -> Some (d, b')
      | None, None -> None)
  | Driver_and_then (a, b) -> (
      match next_state random ~now_ms a with
      | Some (d, a') -> Some (d, Driver_and_then (a', b))
      | None -> next_state random ~now_ms (state_of_schedule b))
  | Driver_jittered (inner, lo, hi) -> (
      match next_state random ~now_ms inner with
      | None -> None
      | Some (d, inner') ->
          let factor =
            lo +. ((hi -. lo) *. Capabilities.random_float random 1.0)
          in
          Some (scale_capped d factor, Driver_jittered (inner', lo, hi)))
  | Driver_named inner -> (
      match next_state random ~now_ms inner with
      | None -> None
      | Some (d, inner') -> Some (d, Driver_named inner'))

let next ?(now_ms = 0) driver =
  match next_state driver.random ~now_ms driver.state with
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
