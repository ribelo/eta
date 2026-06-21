module Body = Stream
module Error = Error
module Header = Header

type mode = Default | Always | Never

type decision =
  | Stop
  | Retry_after of Eta.Duration.t

type packed_schedule = Schedule : (unit, 'output) Eta.Schedule.t -> packed_schedule

type t = {
  mode : mode;
  max_attempts : int;
  schedule : packed_schedule;
  respect_retry_after : bool;
  max_retry_after : Eta.Duration.t;
  retry_status : (int -> bool);
}

let default_retry_status = function
  | 408 | 429 | 502 | 503 | 504 -> true
  | _ -> false

let default_max_retry_after = Eta.Duration.days 1

let default_schedule () =
  Eta.Schedule.exponential ~factor:2.0 (Eta.Duration.ms 100)
  |> Eta.Schedule.either (Eta.Schedule.spaced (Eta.Duration.seconds 30))
  |> Eta.Schedule.jittered ~min:0.0 ~max:1.0

let make ?(mode = Default) ?(max_attempts = 3) ?schedule
    ?(respect_retry_after = true) ?(max_retry_after = default_max_retry_after)
    ?(retry_status = default_retry_status) () =
  if max_attempts <= 0 then
    invalid_arg "Eta_http.Retry_policy.make: max_attempts must be > 0";
  let schedule =
    match schedule with
    | Some schedule -> Schedule schedule
    | None -> Schedule (default_schedule ())
  in
  {
    mode;
    max_attempts;
    schedule;
    respect_retry_after;
    max_retry_after;
    retry_status;
  }

let default = make ()
let never = make ~mode:Never ~max_attempts:1 ()
let always ?max_attempts ?schedule ?retry_status () =
  make ?max_attempts ?schedule ?retry_status ~mode:Always ()

let max_delta_seconds = max_int / 1_000
let max_delay_ms_float = float_of_int max_int

let cap_retry_after ~max_delay delay = Eta.Duration.min delay max_delay

let duration_of_seconds ~max_delay seconds =
  if seconds < 0 || seconds > max_delta_seconds then None
  else Some (cap_retry_after ~max_delay (Eta.Duration.seconds seconds))

let duration_of_delay_ms_float ~max_delay delay_ms =
  if Float.is_nan delay_ms then None
  else if delay_ms <= 0.0 then Some Eta.Duration.zero
  else if delay_ms >= max_delay_ms_float then None
  else Some (cap_retry_after ~max_delay (Eta.Duration.ms (int_of_float delay_ms)))

let month_number = function
  | "Jan" -> Some 1
  | "Feb" -> Some 2
  | "Mar" -> Some 3
  | "Apr" -> Some 4
  | "May" -> Some 5
  | "Jun" -> Some 6
  | "Jul" -> Some 7
  | "Aug" -> Some 8
  | "Sep" -> Some 9
  | "Oct" -> Some 10
  | "Nov" -> Some 11
  | "Dec" -> Some 12
  | _ -> None

let days_from_civil ~year ~month ~day =
  let year = if month <= 2 then year - 1 else year in
  let era = if year >= 0 then year / 400 else (year - 399) / 400 in
  let yoe = year - (era * 400) in
  let month_adjusted = month + if month > 2 then -3 else 9 in
  let doy = ((153 * month_adjusted) + 2) / 5 + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let leap year =
  (year mod 4 = 0 && year mod 100 <> 0) || year mod 400 = 0

let days_in_month ~year = function
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if leap year then 29 else 28
  | _ -> 0

let parse_http_date value =
  try
    Scanf.sscanf value "%3s, %d %3s %d %d:%d:%d GMT"
      (fun _weekday day month_name year hour minute second ->
        match month_number month_name with
        | None -> None
        | Some month ->
            let valid =
              day >= 1
              && day <= days_in_month ~year month
              && hour >= 0 && hour <= 23
              && minute >= 0 && minute <= 59
              && second >= 0 && second <= 59
            in
            if not valid then None
            else
              let days = days_from_civil ~year ~month ~day in
              Some
                (float_of_int
                   (((days * 24 + hour) * 60 + minute) * 60 + second)))
  with _ -> None

let retry_after ?(max_delay = default_max_retry_after) ?(now_s = 0.0) value =
  let value = String.trim value in
  match
    if Eta.String_helpers.starts_with value ~prefix:"+" then None
    else int_of_string_opt value
  with
  | Some seconds -> duration_of_seconds ~max_delay seconds
  | _ -> (
      match parse_http_date value with
      | None -> None
      | Some epoch_s ->
          duration_of_delay_ms_float ~max_delay
            (ceil ((epoch_s -. now_s) *. 1000.0)))

let request_allowed t request =
  match t.mode with
  | Never -> false
  | Always -> Idempotency.body_replayable request
  | Default -> Idempotency.retryable request

let now_ms_of_seconds now_s =
  let now_ms = now_s *. 1000.0 in
  if now_ms <= 0.0 then 0
  else if now_ms >= float_of_int max_int then max_int
  else int_of_float now_ms

let schedule_delay t ~now_s ~attempt =
  let (Schedule schedule) = t.schedule in
  let rec loop driver remaining =
    match Eta.Schedule.next ~now_ms:(now_ms_of_seconds now_s) ~input:() driver with
    | None -> None
    | Some (metadata, driver) ->
        if remaining <= 0 then Some metadata.delay
        else loop driver (remaining - 1)
  in
  loop (Eta.Schedule.start schedule) (attempt - 1)

let retry_after_header t ~now_s headers =
  match Header.get "retry-after" headers with
  | None -> None
  | Some value -> retry_after ~max_delay:t.max_retry_after ~now_s value

let delay_for_error t ~now_s ~attempt error =
  if attempt >= t.max_attempts then None
  else
    match t.respect_retry_after, error.Error.kind with
    | true, HTTP_status { headers; _ } -> (
        match retry_after_header t ~now_s headers with
        | Some delay -> Some delay
        | None -> schedule_delay t ~now_s ~attempt)
    | _ -> schedule_delay t ~now_s ~attempt

let delay_for_response t ~now_s ~attempt response =
  if attempt >= t.max_attempts then None
  else if t.retry_status response.Response.status then
    match t.respect_retry_after, retry_after_header t ~now_s response.headers with
    | true, Some delay -> Some delay
    | _ -> schedule_delay t ~now_s ~attempt
  else None

let classify_error ?(now_s = 0.0) t ~request ~attempt error =
  if not (request_allowed t request) then Stop
  else
    match Error.retryability error with
    | Not_retryable -> Stop
    | Retryable | Retryable_if_body_replayable -> (
        match delay_for_error t ~now_s ~attempt error with
        | None -> Stop
        | Some delay -> Retry_after delay)

let classify_response ?(now_s = 0.0) t ~request ~attempt response =
  if not (request_allowed t request) then Stop
  else
    match delay_for_response t ~now_s ~attempt response with
    | None -> Stop
    | Some delay -> Retry_after delay

let decision_delay = function
  | Stop -> None
  | Retry_after delay -> Some delay

let add_ms_capped a b =
  if b <= 0 then a else if a > max_int - b then max_int else a + b

let post_delay_check deadline_ms =
  Eta.Effect.Expert.make ~leaf_name:"eta-http.retry.post-delay-check" (fun ctx ->
      let contract = Eta.Effect.Expert.contract ctx in
      try
        contract.Eta.Runtime_contract.yield ();
        contract.Eta.Runtime_contract.check ();
        if contract.Eta.Runtime_contract.now_ms () < deadline_ms then
          Eta.Exit.Error Eta.Cause.interrupt
        else Eta.Exit.Ok ()
      with exn -> Eta.Effect.Expert.exit_of_exn ctx exn)

let delay_then delay eff =
  Eta.Effect.Expert.make ~leaf_name:"eta-http.retry.delay" (fun ctx ->
      let contract = Eta.Effect.Expert.contract ctx in
      let deadline_ms =
        add_ms_capped
          (contract.Eta.Runtime_contract.now_ms ())
          (Eta.Duration.to_ms delay)
      in
      Eta.Effect.delay delay
        (post_delay_check deadline_ms |> Eta.Effect.bind (fun () -> eff))
      |> Eta.Effect.Expert.eval ctx)

let request_once_effect request_once request =
  Eta.Effect.Expert.make ~leaf_name:"eta-http.retry.request-once" (fun ctx ->
      try request_once request |> Eta.Effect.Expert.eval ctx
      with exn -> Eta.Effect.Expert.exit_of_exn ctx exn)

let runtime_now_s =
  Eta.Effect.Expert.make ~leaf_name:"eta-http.retry.now" (fun ctx ->
      let contract = Eta.Effect.Expert.contract ctx in
      Eta.Exit.Ok
        (float_of_int (contract.Eta.Runtime_contract.now_ms ()) /. 1000.0))

let now_s_effect = function
  | Some now_s -> Eta.Effect.sync now_s
  | None -> runtime_now_s

let run ?(policy = default) ?now_s request_once request =
  let rec loop attempt =
    Eta.Effect.catch
      (fun error ->
        now_s_effect now_s
        |> Eta.Effect.bind (fun now_s ->
               match
                 classify_error policy ~now_s ~request ~attempt error
                 |> decision_delay
               with
               | None -> Eta.Effect.fail error
               | Some delay -> delay_then delay (loop (attempt + 1))))
      (request_once_effect request_once request
      |> Eta.Effect.bind (fun response ->
             now_s_effect now_s
             |> Eta.Effect.bind (fun now_s ->
                    match
                      classify_response policy ~now_s ~request ~attempt response
                      |> decision_delay
                    with
                    | None -> Eta.Effect.pure response
                    | Some delay ->
                        Body.discard response.body
                        |> Eta.Effect.bind (fun () ->
                               delay_then delay (loop (attempt + 1))))))
  in
  loop 1
