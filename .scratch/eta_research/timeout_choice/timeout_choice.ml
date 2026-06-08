open Eta

type error =
  [ `Connect_timeout
  | `Tls_handshake_timeout
  | `Request_write_timeout
  | `Response_header_timeout
  | `Response_body_idle_timeout
  | `Total_request_timeout
  | `Pool_acquire_timeout
  | `Timeout
  | `Unexpected of string
  ]

let pp_error ppf = function
  | `Connect_timeout -> Format.pp_print_string ppf "connect_timeout"
  | `Tls_handshake_timeout -> Format.pp_print_string ppf "tls_handshake_timeout"
  | `Request_write_timeout -> Format.pp_print_string ppf "request_write_timeout"
  | `Response_header_timeout -> Format.pp_print_string ppf "response_header_timeout"
  | `Response_body_idle_timeout ->
      Format.pp_print_string ppf "response_body_idle_timeout"
  | `Total_request_timeout -> Format.pp_print_string ppf "total_request_timeout"
  | `Pool_acquire_timeout -> Format.pp_print_string ppf "pool_acquire_timeout"
  | `Timeout -> Format.pp_print_string ppf "raw_timeout"
  | `Unexpected msg -> Format.fprintf ppf "unexpected(%s)" msg

let map_timeout timeout_error eff =
  Effect.timeout (Duration.ms 5) eff
  |> Effect.catch (function
       | `Timeout -> Effect.fail timeout_error
       | #error as err -> Effect.fail err)

let with_total_timeout eff =
  Effect.timeout (Duration.ms 5) eff
  |> Effect.catch (function
       | `Timeout -> Effect.fail `Total_request_timeout
       | #error as err -> Effect.fail err)

type source = { next : unit -> (string option, error) Effect.t }

let source_of_schedule events =
  let remaining = ref events in
  {
    next =
      (fun () ->
        match !remaining with
        | [] -> Effect.pure None
        | (delay_ms, chunk) :: rest ->
            remaining := rest;
            Effect.delay (Duration.ms delay_ms) (Effect.pure (Some chunk)));
  }

let next_with_idle_timeout idle source =
  Effect.timeout idle (source.next ())
  |> Effect.catch (function
       | `Timeout -> Effect.fail `Response_body_idle_timeout
       | #error as err -> Effect.fail err)

let read_n_with_idle ~idle n source =
  let rec loop remaining acc =
    if remaining = 0 then Effect.pure (List.rev acc)
    else
      next_with_idle_timeout idle source
      |> Effect.bind (function
           | None -> Effect.pure (List.rev acc)
           | Some chunk -> loop (remaining - 1) (chunk :: acc))
  in
  loop n []

let run_effect eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  Runtime.run rt eff

let pass label detail = Printf.printf "%s PASS %s\n%!" label detail

let fail label detail =
  Printf.eprintf "%s FAIL %s\n%!" label detail;
  exit 1

let expect_error label expected eff =
  match run_effect eff with
  | Exit.Error (Cause.Fail actual) when actual = expected ->
      pass label (Format.asprintf "error=%a" pp_error actual)
  | Exit.Error cause ->
      fail label
        (Format.asprintf "unexpected_cause=%a" (Cause.pp pp_error) cause)
  | Exit.Ok _ -> fail label "unexpected_success"

let expect_ok_count label expected eff =
  match run_effect eff with
  | Exit.Ok chunks ->
      let actual = List.length chunks in
      if actual = expected then pass label (Printf.sprintf "chunks=%d" actual)
      else fail label (Printf.sprintf "chunks=%d expected=%d" actual expected)
  | Exit.Error cause ->
      fail label
        (Format.asprintf "unexpected_cause=%a" (Cause.pp pp_error) cause)

let stage_timeout_fixtures () =
  let slow_stage = Effect.delay (Duration.ms 20) Effect.unit in
  expect_error "connect_timeout" `Connect_timeout
    (map_timeout `Connect_timeout slow_stage);
  expect_error "tls_handshake_timeout" `Tls_handshake_timeout
    (map_timeout `Tls_handshake_timeout slow_stage);
  expect_error "request_write_timeout" `Request_write_timeout
    (map_timeout `Request_write_timeout slow_stage);
  expect_error "response_header_timeout" `Response_header_timeout
    (map_timeout `Response_header_timeout slow_stage);
  expect_error "pool_acquire_timeout" `Pool_acquire_timeout
    (map_timeout `Pool_acquire_timeout slow_stage)

let body_idle_fixtures () =
  let idle = Duration.ms 5 in
  let slowloris = source_of_schedule [ (0, "a"); (20, "b") ] in
  expect_error "body_idle_stall" `Response_body_idle_timeout
    (read_n_with_idle ~idle 2 slowloris);
  let fast =
    source_of_schedule (List.init 200 (fun i -> (0, string_of_int i)))
  in
  expect_ok_count "fast_download_not_killed_by_idle" 200
    (read_n_with_idle ~idle 200 fast)

let sse_fixtures () =
  let idle = Duration.ms 5 in
  let heartbeat =
    source_of_schedule (List.init 10 (fun i -> (2, ":heartbeat-" ^ string_of_int i)))
  in
  expect_ok_count "sse_heartbeat_happy_path" 10
    (read_n_with_idle ~idle 10 heartbeat);
  let stalled =
    source_of_schedule [ (0, ":heartbeat-0"); (2, ":heartbeat-1"); (20, "data") ]
  in
  expect_error "sse_stall" `Response_body_idle_timeout
    (read_n_with_idle ~idle 3 stalled)

let total_timeout_fixtures () =
  let idle = Duration.ms 5 in
  let slow_progress =
    source_of_schedule (List.init 10 (fun i -> (2, string_of_int i)))
  in
  expect_error "total_request_timeout_progressing_body" `Total_request_timeout
    (with_total_timeout (read_n_with_idle ~idle 10 slow_progress));
  let total_only_sse =
    source_of_schedule (List.init 10 (fun i -> (2, ":heartbeat-" ^ string_of_int i)))
  in
  expect_error "single_total_timeout_kills_valid_sse" `Total_request_timeout
    (with_total_timeout (read_n_with_idle ~idle 10 total_only_sse))

let () =
  stage_timeout_fixtures ();
  body_idle_fixtures ();
  sse_fixtures ();
  total_timeout_fixtures ()
