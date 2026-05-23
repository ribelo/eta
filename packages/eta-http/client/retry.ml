module Body = Eta_http_body.Stream
module Error = Eta_http_error.Error
module Header = Eta_http_core.Header

type mode = Default | Always | Never

type decision =
  | Stop
  | Retry_after of Eta.Duration.t
  | Retry_with_new_connection of Eta.Duration.t

type t = {
  mode : mode;
  max_attempts : int;
  schedule : Eta.Schedule.t;
  respect_retry_after : bool;
}

let make ?(mode = Default) ?(max_attempts = 3)
    ?(schedule =
      Eta.Schedule.exponential ~factor:2.0 (Eta.Duration.ms 100)
      |> Eta.Schedule.either (Eta.Schedule.spaced (Eta.Duration.seconds 30))
      |> Eta.Schedule.jittered ~min:0.0 ~max:1.0)
    ?(respect_retry_after = true) () =
  { mode; max_attempts = max 1 max_attempts; schedule; respect_retry_after }

let default = make ()
let never = make ~mode:Never ~max_attempts:1 ()
let always ?max_attempts ?schedule () = make ?max_attempts ?schedule ~mode:Always ()

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

let parse_http_date value =
  try
    Scanf.sscanf value "%3s, %d %3s %d %d:%d:%d GMT"
      (fun _weekday day month_name year hour minute second ->
        match month_number month_name with
        | None -> None
        | Some month ->
            let days = days_from_civil ~year ~month ~day in
            Some
              (float_of_int
                 (((days * 24 + hour) * 60 + minute) * 60 + second)))
  with _ -> None

let retry_after ?(now_s = 0.0) value =
  let value = String.trim value in
  match int_of_string_opt value with
  | Some seconds when seconds >= 0 -> Some (Eta.Duration.seconds seconds)
  | _ -> (
      match parse_http_date value with
      | None -> None
      | Some epoch_s ->
          let delay_ms = int_of_float (ceil ((epoch_s -. now_s) *. 1000.0)) in
          Some (Eta.Duration.ms (max 0 delay_ms)))

let request_allowed t request =
  match t.mode with
  | Never -> false
  | Always -> Idempotency.body_replayable request
  | Default -> Idempotency.retryable request

let schedule_delay t ~attempt =
  Eta.Schedule.next_delay t.schedule ~step:(attempt - 1)

let retry_after_header headers =
  match Header.get "retry-after" headers with
  | None -> None
  | Some value -> retry_after value

let delay_for_error t ~attempt error =
  if attempt >= t.max_attempts then None
  else
    match t.respect_retry_after, error.Error.kind with
    | true, HTTP_status { headers; _ } -> (
        match retry_after_header headers with
        | Some delay -> Some delay
        | None -> schedule_delay t ~attempt)
    | _ -> schedule_delay t ~attempt

let retryable_status = function
  | 408 | 429 | 502 | 503 | 504 -> true
  | _ -> false

let delay_for_response t ~attempt response =
  if attempt >= t.max_attempts then None
  else if retryable_status response.Response.status then
    match t.respect_retry_after, retry_after_header response.headers with
    | true, Some delay -> Some delay
    | _ -> schedule_delay t ~attempt
  else None

let classify_error t ~request ~attempt error =
  if not (request_allowed t request) then Stop
  else
    match Error.retryability error with
    | Not_retryable -> Stop
    | Retryable | Retryable_if_body_replayable -> (
        match delay_for_error t ~attempt error with
        | None -> Stop
        | Some delay -> (
            match error.kind with
            | Connection_closed _ -> Retry_with_new_connection delay
            | _ -> Retry_after delay))

let classify_response t ~request ~attempt response =
  if not (request_allowed t request) then Stop
  else
    match delay_for_response t ~attempt response with
    | None -> Stop
    | Some delay -> Retry_after delay

let decision_delay = function
  | Stop -> None
  | Retry_after delay | Retry_with_new_connection delay -> Some delay

let run ?(policy = default) request_once request =
  let rec loop attempt =
    Eta.Effect.catch
      (fun error ->
        match classify_error policy ~request ~attempt error |> decision_delay with
        | None -> Eta.Effect.fail error
        | Some delay -> Eta.Effect.delay delay (loop (attempt + 1)))
      (request_once request
      |> Eta.Effect.bind (fun response ->
             match
               classify_response policy ~request ~attempt response |> decision_delay
             with
             | None -> Eta.Effect.pure response
             | Some delay ->
                 Body.discard response.body
                 |> Eta.Effect.bind (fun () ->
                        Eta.Effect.delay delay (loop (attempt + 1)))))
  in
  loop 1
