type ('left, 'right) and_then_output =
  | First_phase of 'left
  | Second_phase of 'right

type (_, _) t =
  | Recurs : int -> ('input, int) t
  | Forever : ('input, int) t
  | Spaced : Duration.t -> ('input, int) t
  | Fixed : Duration.t -> ('input, int) t
  | Windowed : Duration.t -> ('input, int) t
  | Exponential : Duration.t * float -> ('input, Duration.t) t
  | Fibonacci : Duration.t -> ('input, Duration.t) t
  | Linear : { initial : Duration.t; step : Duration.t } -> ('input, Duration.t) t
  | Elapsed : ('input, Duration.t) t
  | During : Duration.t -> ('input, Duration.t) t
  | Recur_until : ('input -> bool) -> ('input, 'input) t
  | Both : ('input, 'a) t * ('input, 'b) t -> ('input, 'a * 'b) t
  | Either : ('input, 'a) t * ('input, 'b) t -> ('input, 'a * 'b) t
  | And_then :
      ('input, 'left) t * ('input, 'right) t
      -> ('input, ('left, 'right) and_then_output) t
  | Modify_delay :
      ('output -> Duration.t -> Duration.t) * ('input, 'output) t
      -> ('input, 'output) t
  | While_output :
      ('output -> bool) * ('input, 'output) t -> ('input, 'output) t
  | Tap_input :
      ('input -> unit) * ('input, 'output) t -> ('input, 'output) t
  | Tap_output :
      ('output -> unit) * ('input, 'output) t -> ('input, 'output) t
  | Jittered : ('input, 'output) t * float * float -> ('input, 'output) t
  | Named : ('input, 'output) t * string -> ('input, 'output) t

type ('input, 'output) metadata = {
  input : 'input;
  output : 'output;
  attempt : int;
  start_ms : int;
  now_ms : int;
  elapsed : Duration.t;
  elapsed_since_previous : Duration.t;
  delay : Duration.t;
}

type ('input, 'output) decision =
  | Continue of ('input, 'output) metadata
  | Done of ('input, 'output) metadata

let recurs n = Recurs (max 0 n)
let forever = Forever
let spaced d = Spaced d
let fixed d = Fixed d
let windowed d = Windowed d
let exponential ?(factor = 2.0) initial = Exponential (initial, factor)
let fibonacci initial = Fibonacci initial
let linear ~initial ~step = Linear { initial; step }
let elapsed = Elapsed
let during d = During d
let recur_until pred = Recur_until pred
let both a b = Both (a, b)
let either a b = Either (a, b)
let and_then a b = And_then (a, b)
let modify_delay f self = Modify_delay (f, self)
let while_output f self = While_output (f, self)
let tap_input f self = Tap_input (f, self)
let tap_output f self = Tap_output (f, self)

let jittered ?(min = 0.8) ?(max = 1.2) self =
  let lo = if min < 0.0 then 0.0 else min in
  let hi = if max < lo then lo else max in
  Jittered (self, lo, hi)

let named name s = Named (s, name)

let rec pp : type input output. Format.formatter -> (input, output) t -> unit =
 fun ppf -> function
  | Recurs n -> Format.fprintf ppf "Recurs(%d)" n
  | Forever -> Format.fprintf ppf "Forever"
  | Spaced d -> Format.fprintf ppf "Spaced(%a)" Duration.pp d
  | Fixed d -> Format.fprintf ppf "Fixed(%a)" Duration.pp d
  | Windowed d -> Format.fprintf ppf "Windowed(%a)" Duration.pp d
  | Exponential (d, f) -> Format.fprintf ppf "Exponential(%a, %g)" Duration.pp d f
  | Fibonacci d -> Format.fprintf ppf "Fibonacci(%a)" Duration.pp d
  | Linear { initial; step } ->
      Format.fprintf ppf "Linear(%a, %a)" Duration.pp initial Duration.pp step
  | Elapsed -> Format.fprintf ppf "Elapsed"
  | During d -> Format.fprintf ppf "During(%a)" Duration.pp d
  | Recur_until _ -> Format.fprintf ppf "RecurUntil(<fun>)"
  | Both (a, b) -> Format.fprintf ppf "Both(%a,%a)" pp a pp b
  | Either (a, b) -> Format.fprintf ppf "Either(%a,%a)" pp a pp b
  | And_then (a, b) -> Format.fprintf ppf "AndThen(%a,%a)" pp a pp b
  | Modify_delay (_, s) -> Format.fprintf ppf "ModifyDelay(%a)" pp s
  | While_output (_, s) -> Format.fprintf ppf "WhileOutput(%a)" pp s
  | Tap_input (_, s) -> Format.fprintf ppf "TapInput(%a)" pp s
  | Tap_output (_, s) -> Format.fprintf ppf "TapOutput(%a)" pp s
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
let duration_since ~start now_ms = Duration.ms (elapsed_since ~start now_ms)

type meta_state = {
  meta_attempt : int;
  meta_start_ms : int option;
  meta_previous_ms : int option;
}

type 'input input_metadata = {
  input : 'input;
  attempt : int;
  start_ms : int;
  now_ms : int;
  elapsed : Duration.t;
  elapsed_since_previous : Duration.t;
}

let initial_meta_state =
  { meta_attempt = 0; meta_start_ms = None; meta_previous_ms = None }

let next_input_metadata ~now_ms ~input state =
  let start_ms = Option.value state.meta_start_ms ~default:now_ms in
  let elapsed_since_previous =
    match state.meta_previous_ms with
    | None -> Duration.zero
    | Some previous_ms -> duration_since ~start:previous_ms now_ms
  in
  let metadata =
    {
      input;
      attempt = state.meta_attempt + 1;
      start_ms;
      now_ms;
      elapsed = duration_since ~start:start_ms now_ms;
      elapsed_since_previous;
    }
  in
  ( metadata,
    {
      meta_attempt = metadata.attempt;
      meta_start_ms = Some start_ms;
      meta_previous_ms = Some now_ms;
    } )

let output_metadata input_meta ~output ~delay =
  {
    input = input_meta.input;
    output;
    attempt = input_meta.attempt;
    start_ms = input_meta.start_ms;
    now_ms = input_meta.now_ms;
    elapsed = input_meta.elapsed;
    elapsed_since_previous = input_meta.elapsed_since_previous;
    delay;
  }

let continue input_meta ~output ~delay =
  Continue (output_metadata input_meta ~output ~delay)

let done_ input_meta ~output =
  Done (output_metadata input_meta ~output ~delay:Duration.zero)

let map_continue_delay decision f =
  match decision with
  | Done _ as done_ -> done_
  | Continue metadata -> Continue { metadata with delay = f metadata.delay }

let default_random = lazy (Capabilities.random_default ())

type (_, _) state =
  | Driver_recurs : {
      times : int;
      count : int;
      meta : meta_state;
    } -> ('input, int) state
  | Driver_forever : {
      count : int;
      meta : meta_state;
    } -> ('input, int) state
  | Driver_spaced : {
      duration : Duration.t;
      count : int;
      meta : meta_state;
    } -> ('input, int) state
  | Driver_fixed : {
      interval : Duration.t;
      count : int;
      last_run_ms : int option;
      meta : meta_state;
    } -> ('input, int) state
  | Driver_windowed : {
      interval : Duration.t;
      count : int;
      meta : meta_state;
    } -> ('input, int) state
  | Driver_exponential : {
      initial : Duration.t;
      factor : float;
      index : int;
      meta : meta_state;
    } -> ('input, Duration.t) state
  | Driver_fibonacci : {
      previous : Duration.t;
      current : Duration.t;
      meta : meta_state;
    } -> ('input, Duration.t) state
  | Driver_linear : {
      initial : Duration.t;
      step : Duration.t;
      index : int;
      meta : meta_state;
    } -> ('input, Duration.t) state
  | Driver_elapsed : {
      meta : meta_state;
    } -> ('input, Duration.t) state
  | Driver_during : {
      duration : Duration.t;
      meta : meta_state;
    } -> ('input, Duration.t) state
  | Driver_recur_until : {
      predicate : 'input -> bool;
      meta : meta_state;
    } -> ('input, 'input) state
  | Driver_both : ('input, 'a) phase * ('input, 'b) phase -> ('input, 'a * 'b) state
  | Driver_either : ('input, 'a) phase * ('input, 'b) phase -> ('input, 'a * 'b) state
  | Driver_and_then_first :
      ('input, 'left) state * ('input, 'right) t
      -> ('input, ('left, 'right) and_then_output) state
  | Driver_and_then_second :
      ('input, 'right) state -> ('input, ('left, 'right) and_then_output) state
  | Driver_modify_delay :
      ('output -> Duration.t -> Duration.t) * ('input, 'output) state
      -> ('input, 'output) state
  | Driver_while_output :
      ('output -> bool) * ('input, 'output) state -> ('input, 'output) state
  | Driver_tap_input :
      ('input -> unit) * ('input, 'output) state -> ('input, 'output) state
  | Driver_tap_output :
      ('output -> unit) * ('input, 'output) state -> ('input, 'output) state
  | Driver_jittered : ('input, 'output) state * float * float -> ('input, 'output) state
  | Driver_named : ('input, 'output) state -> ('input, 'output) state

and (_, _) phase =
  | Active : ('input, 'output) state -> ('input, 'output) phase
  | Finished : ('input, 'output) metadata -> ('input, 'output) phase

let rec state_of_schedule : type input output. (input, output) t -> (input, output) state =
 function
  | Recurs n -> Driver_recurs { times = n; count = 0; meta = initial_meta_state }
  | Forever -> Driver_forever { count = 0; meta = initial_meta_state }
  | Spaced duration ->
      Driver_spaced { duration; count = 0; meta = initial_meta_state }
  | Fixed interval ->
      Driver_fixed
        { interval; count = 0; last_run_ms = None; meta = initial_meta_state }
  | Windowed interval ->
      Driver_windowed { interval; count = 0; meta = initial_meta_state }
  | Exponential (initial, factor) ->
      Driver_exponential { initial; factor; index = 0; meta = initial_meta_state }
  | Fibonacci initial ->
      Driver_fibonacci
        { previous = Duration.zero; current = initial; meta = initial_meta_state }
  | Linear { initial; step } ->
      Driver_linear { initial; step; index = 0; meta = initial_meta_state }
  | Elapsed -> Driver_elapsed { meta = initial_meta_state }
  | During duration -> Driver_during { duration; meta = initial_meta_state }
  | Recur_until predicate ->
      Driver_recur_until { predicate; meta = initial_meta_state }
  | Both (a, b) ->
      Driver_both (Active (state_of_schedule a), Active (state_of_schedule b))
  | Either (a, b) ->
      Driver_either (Active (state_of_schedule a), Active (state_of_schedule b))
  | And_then (a, b) -> Driver_and_then_first (state_of_schedule a, b)
  | Modify_delay (f, inner) -> Driver_modify_delay (f, state_of_schedule inner)
  | While_output (f, inner) -> Driver_while_output (f, state_of_schedule inner)
  | Tap_input (f, inner) -> Driver_tap_input (f, state_of_schedule inner)
  | Tap_output (f, inner) -> Driver_tap_output (f, state_of_schedule inner)
  | Jittered (inner, lo, hi) -> Driver_jittered (state_of_schedule inner, lo, hi)
  | Named (inner, _) -> Driver_named (state_of_schedule inner)

let current_metadata = function Continue metadata | Done metadata -> metadata
let output_of_decision decision = (current_metadata decision).output

let combine_metadata :
    type input previous output.
    (input, previous) metadata -> output:output -> delay:Duration.t -> (input, output) metadata =
 fun basis ~output ~delay ->
  {
    input = basis.input;
    output;
    attempt = basis.attempt;
    start_ms = basis.start_ms;
    now_ms = basis.now_ms;
    elapsed = basis.elapsed;
    elapsed_since_previous = basis.elapsed_since_previous;
    delay;
  }

let step_result_phase decision state =
  match decision with
  | Continue _ -> Active state
  | Done metadata -> Finished metadata

let rec step_phase :
    type input output.
    Capabilities.random ->
    now_ms:int ->
    input:input ->
    (input, output) phase ->
    (input, output) decision * (input, output) phase =
 fun random ~now_ms ~input -> function
  | Finished metadata -> (Done metadata, Finished metadata)
  | Active state ->
      let decision, state = step_state random ~now_ms ~input state in
      (decision, step_result_phase decision state)

and step_state :
    type input output.
    Capabilities.random ->
    now_ms:int ->
    input:input ->
    (input, output) state ->
    (input, output) decision * (input, output) state =
 fun random ~now_ms ~input -> function
  | Driver_recurs { times; count; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let state = Driver_recurs { times; count = count + 1; meta } in
      let decision =
        if count < times then continue input_meta ~output:count ~delay:Duration.zero
        else done_ input_meta ~output:count
      in
      (decision, state)
  | Driver_forever { count; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      ( continue input_meta ~output:count ~delay:Duration.zero,
        Driver_forever { count = count + 1; meta } )
  | Driver_spaced { duration; count; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      ( continue input_meta ~output:count ~delay:duration,
        Driver_spaced { duration; count = count + 1; meta } )
  | Driver_fixed { interval; count; last_run_ms; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let interval_ms = Duration.to_ms interval in
      let delay_ms, last_run_ms =
        if interval_ms = 0 then (0, last_run_ms)
        else
          match last_run_ms with
          | None -> (interval_ms, Some (add_ms_capped now_ms interval_ms))
          | Some last_run_ms ->
              let running_behind = now_ms > add_ms_capped last_run_ms interval_ms in
              let elapsed_ms = elapsed_since ~start:input_meta.start_ms now_ms in
              let boundary = interval_ms - (elapsed_ms mod interval_ms) in
              let delay_ms =
                if running_behind then 0
                else if boundary = 0 then interval_ms
                else boundary
              in
              let next_run_ms =
                if running_behind then now_ms else add_ms_capped now_ms delay_ms
              in
              (delay_ms, Some next_run_ms)
      in
      ( continue input_meta ~output:count ~delay:(Duration.ms delay_ms),
        Driver_fixed
          { interval; count = count + 1; last_run_ms; meta } )
  | Driver_windowed { interval; count; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let interval_ms = Duration.to_ms interval in
      let delay_ms =
        if interval_ms = 0 then 0
        else
          let elapsed_ms = Duration.to_ms input_meta.elapsed in
          let boundary = interval_ms - (elapsed_ms mod interval_ms) in
          if boundary = 0 then interval_ms else boundary
      in
      ( continue input_meta ~output:count ~delay:(Duration.ms delay_ms),
        Driver_windowed { interval; count = count + 1; meta } )
  | Driver_exponential { initial; factor; index; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let duration = scale_capped initial (pow_factor factor index) in
      ( continue input_meta ~output:duration ~delay:duration,
        Driver_exponential { initial; factor; index = index + 1; meta } )
  | Driver_fibonacci { previous; current; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let next = add_capped previous current in
      ( continue input_meta ~output:current ~delay:current,
        Driver_fibonacci { previous = current; current = next; meta } )
  | Driver_linear { initial; step; index; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let delta = scale_capped step (float_of_int index) in
      let duration = add_capped initial delta in
      ( continue input_meta ~output:duration ~delay:duration,
        Driver_linear { initial; step; index = index + 1; meta } )
  | Driver_elapsed { meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      ( continue input_meta ~output:input_meta.elapsed ~delay:Duration.zero,
        Driver_elapsed { meta } )
  | Driver_during { duration; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let output = input_meta.elapsed in
      let decision =
        if Duration.compare output duration <= 0 then
          continue input_meta ~output ~delay:Duration.zero
        else done_ input_meta ~output
      in
      (decision, Driver_during { duration; meta })
  | Driver_recur_until { predicate; meta } ->
      let input_meta, meta = next_input_metadata ~now_ms ~input meta in
      let decision =
        if predicate input then done_ input_meta ~output:input
        else continue input_meta ~output:input ~delay:Duration.zero
      in
      (decision, Driver_recur_until { predicate; meta })
  | Driver_both (left, right) ->
      let left_decision, left = step_phase random ~now_ms ~input left in
      let right_decision, right = step_phase random ~now_ms ~input right in
      let output = (output_of_decision left_decision, output_of_decision right_decision) in
      let decision =
        match (left_decision, right_decision) with
        | Continue left_metadata, Continue right_metadata ->
            Continue
              (combine_metadata left_metadata ~output
                 ~delay:(Duration.max left_metadata.delay right_metadata.delay))
        | Continue left_metadata, Done _ ->
            Done (combine_metadata left_metadata ~output ~delay:Duration.zero)
        | Done _, Continue right_metadata ->
            Done (combine_metadata right_metadata ~output ~delay:Duration.zero)
        | Done left_metadata, Done _ ->
            Done (combine_metadata left_metadata ~output ~delay:Duration.zero)
      in
      (decision, Driver_both (left, right))
  | Driver_either (left, right) ->
      let left_decision, left = step_phase random ~now_ms ~input left in
      let right_decision, right = step_phase random ~now_ms ~input right in
      let output = (output_of_decision left_decision, output_of_decision right_decision) in
      let decision =
        match (left_decision, right_decision) with
        | Continue left_metadata, Continue right_metadata ->
            Continue
              (combine_metadata left_metadata ~output
                 ~delay:(Duration.min left_metadata.delay right_metadata.delay))
        | Continue left_metadata, Done _ ->
            Continue (combine_metadata left_metadata ~output ~delay:left_metadata.delay)
        | Done _, Continue right_metadata ->
            Continue (combine_metadata right_metadata ~output ~delay:right_metadata.delay)
        | Done left_metadata, Done _ ->
            Done (combine_metadata left_metadata ~output ~delay:Duration.zero)
      in
      (decision, Driver_either (left, right))
  | Driver_and_then_first (left, right_schedule) -> (
      let left_decision, left_state = step_state random ~now_ms ~input left in
      match left_decision with
      | Continue metadata ->
          ( Continue { metadata with output = First_phase metadata.output },
            Driver_and_then_first (left_state, right_schedule) )
      | Done _ ->
          let right_state = state_of_schedule right_schedule in
          step_state random ~now_ms ~input (Driver_and_then_second right_state))
  | Driver_and_then_second state ->
      let decision, state = step_state random ~now_ms ~input state in
      let decision =
        match decision with
        | Continue metadata ->
            Continue { metadata with output = Second_phase metadata.output }
        | Done metadata ->
            Done { metadata with output = Second_phase metadata.output }
      in
      (decision, Driver_and_then_second state)
  | Driver_modify_delay (f, inner) ->
      let decision, inner = step_state random ~now_ms ~input inner in
      ( map_continue_delay decision (fun delay ->
            f (current_metadata decision).output delay),
        Driver_modify_delay (f, inner) )
  | Driver_while_output (predicate, inner) ->
      let decision, inner = step_state random ~now_ms ~input inner in
      let decision =
        match decision with
        | Done _ as done_ -> done_
        | Continue metadata ->
            if predicate metadata.output then Continue metadata
            else Done { metadata with delay = Duration.zero }
      in
      (decision, Driver_while_output (predicate, inner))
  | Driver_tap_input (f, inner) ->
      f input;
      let decision, inner = step_state random ~now_ms ~input inner in
      (decision, Driver_tap_input (f, inner))
  | Driver_tap_output (f, inner) ->
      let decision, inner = step_state random ~now_ms ~input inner in
      f (current_metadata decision).output;
      (decision, Driver_tap_output (f, inner))
  | Driver_jittered (inner, lo, hi) ->
      let decision, inner = step_state random ~now_ms ~input inner in
      let decision =
        map_continue_delay decision @@ fun delay ->
        let factor = lo +. ((hi -. lo) *. Capabilities.random_float random 1.0) in
        scale_capped delay factor
      in
      (decision, Driver_jittered (inner, lo, hi))
  | Driver_named inner ->
      let decision, inner = step_state random ~now_ms ~input inner in
      (decision, Driver_named inner)

type ('input, 'output) driver = {
  random : Capabilities.random;
  phase : ('input, 'output) phase;
}

let start ?(random = Lazy.force default_random) schedule =
  { random; phase = Active (state_of_schedule schedule) }

let step ~now_ms ~input driver =
  let decision, phase = step_phase driver.random ~now_ms ~input driver.phase in
  (decision, { driver with phase })

let next ~now_ms ~input driver =
  match step ~now_ms ~input driver with
  | Continue metadata, driver -> Some (metadata, driver)
  | Done _, _ -> None
