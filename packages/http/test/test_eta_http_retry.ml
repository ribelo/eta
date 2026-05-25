open Test_eta_http_support

let test_idempotency_classifier () =
  let get =
    Http.Request.make ~body:(Fixed [ Bytes.of_string "x" ]) "GET"
      "https://api.example.test/resource"
  in
  Alcotest.(check bool) "GET retryable" true
    (Http.Idempotency.retryable get);
  let post =
    Http.Request.make ~body:(Fixed [ Bytes.of_string "x" ]) "POST"
      "https://api.example.test/resource"
  in
  Alcotest.(check bool) "POST default" false
    (Http.Idempotency.retryable post);
  let post_with_key = Http.Idempotency.with_idempotency_key "k1" post in
  Alcotest.(check bool) "POST with key" true
    (Http.Idempotency.retryable post_with_key);
  let one_shot =
    Http.Request.make
      ~body:(Stream (Http.Body.Stream.of_bytes [ Bytes.of_string "x" ]))
      "GET" "https://api.example.test/resource"
  in
  Alcotest.(check bool) "one-shot body" false
    (Http.Idempotency.retryable one_shot)

let test_retry_after_parser () =
  let seconds =
    Http.Retry_policy.retry_after "5" |> Option.map Eta.Duration.to_ms
  in
  Alcotest.(check (option int)) "delta seconds" (Some 5000) seconds;
  let http_date =
    Http.Retry_policy.retry_after ~now_s:1445412475.0
      "Wed, 21 Oct 2015 07:28:00 GMT"
    |> Option.map Eta.Duration.to_ms
  in
  Alcotest.(check (option int)) "http date" (Some 5000) http_date

let http_date_of_epoch_s epoch_s =
  let tm = Unix.gmtime epoch_s in
  let weekdays =
    [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]
  in
  let months =
    [|
      "Jan";
      "Feb";
      "Mar";
      "Apr";
      "May";
      "Jun";
      "Jul";
      "Aug";
      "Sep";
      "Oct";
      "Nov";
      "Dec";
    |]
  in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
    weekdays.(tm.Unix.tm_wday) tm.Unix.tm_mday months.(tm.Unix.tm_mon)
    (tm.Unix.tm_year + 1900) tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let retry_after_delay_ms = function
  | Http.Retry_policy.Retry_after delay -> Eta.Duration.to_ms delay
  | Stop -> Alcotest.fail "retry stopped"

let test_retry_after_absolute_date_uses_clock () =
  let policy =
    Http.Retry_policy.make ~max_attempts:2
      ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 999))
      ()
  in
  let request = Http.Request.make "GET" "https://api.example.test/retry" in
  let now_s = 1_445_412_475.0 in
  let classify headers =
    Http.Retry_policy.classify_response policy ~now_s ~request ~attempt:1
      (retry_response ~headers 503)
    |> retry_after_delay_ms
  in
  Alcotest.(check int) "absolute future date" 5_000
    (classify [ "Retry-After", http_date_of_epoch_s (now_s +. 5.0) ]);
  Alcotest.(check int) "numeric seconds" 5_000
    (classify [ "Retry-After", "5" ]);
  Alcotest.(check int) "past date clamps" 0
    (classify [ "Retry-After", http_date_of_epoch_s (now_s -. 5.0) ])

let test_retry_policy_schedule_backoff () =
  let policy =
    Http.Retry_policy.make ~max_attempts:2
      ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
      ~respect_retry_after:false ()
  in
  let request =
    Http.Request.make "GET" "https://api.example.test/retry"
  in
  let response = retry_response 503 in
  match
    Http.Retry_policy.classify_response policy ~request ~attempt:1 response
  with
  | Retry_after delay ->
      Alcotest.(check int) "delay" 7 (Eta.Duration.to_ms delay)
  | Stop -> Alcotest.fail "retry stopped"

let test_retry_policy_rejects_invalid_max_attempts () =
  Alcotest.check_raises "max_attempts must be positive"
    (Invalid_argument "Http.Retry_policy.make: max_attempts must be > 0")
    (fun () ->
      ignore
        (Http.Retry_policy.make ~max_attempts:0 ()
          : Http.Retry_policy.t))

let test_retry_policy_max_attempts_one_does_not_retry () =
  let policy =
    Http.Retry_policy.make ~max_attempts:1
      ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
      ()
  in
  let request =
    Http.Request.make "GET" "https://api.example.test/retry"
  in
  match
    Http.Retry_policy.classify_response policy ~request ~attempt:1
      (retry_response 503)
  with
  | Stop -> ()
  | Retry_after _ -> Alcotest.fail "retry should stop after one attempt"

let test_retry_policy_connection_closed_is_generic_retry () =
  let policy =
    Http.Retry_policy.make ~max_attempts:2
      ~schedule:(Eta.Schedule.spaced (Eta.Duration.ms 7))
      ~respect_retry_after:false ()
  in
  let uri = "https://api.example.test/retry" in
  let request = Http.Request.make "GET" uri in
  let error =
    Http.Error.make ~protocol:H1 ~method_:"GET" ~uri
      (Connection_closed { during = Http_response })
  in
  match Http.Retry_policy.classify_error policy ~request ~attempt:1 error with
  | Retry_after delay ->
      Alcotest.(check int) "delay" 7 (Eta.Duration.to_ms delay)
  | Stop -> Alcotest.fail "retry stopped"

let otlp_retry_status = function
  | 429 | 502 | 503 | 504 -> true
  | _ -> false

let test_retry_policy_custom_status_classifier () =
  Test.with_test_clock @@ fun _sw _clock rt ->
  let request = Http.Request.make "GET" "https://api.example.test/retry" in
  Alcotest.(check bool) "default retries 408" true
    (Http.Retry_policy.default_retry_status 408);
  Alcotest.(check bool) "otlp rejects 408" false (otlp_retry_status 408);
  let policy =
    Http.Retry_policy.make ~max_attempts:3
      ~schedule:(Eta.Schedule.spaced Eta.Duration.zero)
      ~retry_status:otlp_retry_status ()
  in
  let assert_status_decision status expected =
    let response = retry_response status in
    let actual =
      match
        Http.Retry_policy.classify_response policy ~request ~attempt:1
          response
      with
      | Retry_after _ -> true
      | Stop -> false
    in
    Alcotest.(check bool)
      (Printf.sprintf "retry status %d" status)
      expected actual
  in
  assert_status_decision 400 false;
  assert_status_decision 408 false;
  assert_status_decision 429 true;
  assert_status_decision 502 true;
  assert_status_decision 503 true;
  assert_status_decision 504 true;
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 408);
        (fun () -> retry_response 200);
      |]
  in
  let response =
    Eta.Runtime.run rt (Http.request_with_retry ~policy client request)
    |> Test.Expect.expect_ok
  in
  Alcotest.(check int) "408 status" 408 response.status;
  Alcotest.(check int) "408 attempts" 1 !attempts;
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 429);
        (fun () -> retry_response 200);
      |]
  in
  let response =
    Eta.Runtime.run rt (Http.request_with_retry ~policy client request)
    |> Test.Expect.expect_ok
  in
  Alcotest.(check int) "429 final status" 200 response.status;
  Alcotest.(check int) "429 attempts" 2 !attempts

let test_retry_succeeds_on_third_attempt () =
  Test.with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let attempts, client =
    retry_client
      [|
        (fun () ->
          retry_response ~headers:[ "Retry-After", "0" ]
            ~release:(fun () ->
              incr released;
              Eta.Effect.unit)
            503);
        (fun () ->
          retry_response ~headers:[ "Retry-After", "0" ]
            ~release:(fun () ->
              incr released;
              Eta.Effect.unit)
            503);
        (fun () -> retry_response 200);
      |]
  in
  let request = Http.Request.make "GET" "https://api.example.test/retry" in
  let response =
    Eta.Runtime.run rt (Http.request_with_retry client request)
    |> Test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check int) "attempts" 3 !attempts;
  Alcotest.(check int) "discard failed bodies" 2 !released

let test_retry_non_idempotent_requires_opt_in () =
  Test.with_test_clock @@ fun _sw _clock rt ->
  let post =
    Http.Request.make ~body:(Fixed [ Bytes.of_string "payload" ]) "POST"
      "https://api.example.test/retry"
  in
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let response =
    Eta.Runtime.run rt (Http.request_with_retry client post)
    |> Test.Expect.expect_ok
  in
  Alcotest.(check int) "default status" 503 response.status;
  Alcotest.(check int) "default attempts" 1 !attempts;
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let response =
    Eta.Runtime.run rt
      (Http.request_with_retry client
         (Http.Idempotency.with_idempotency_key "key-1" post))
    |> Test.Expect.expect_ok
  in
  Alcotest.(check int) "key status" 200 response.status;
  Alcotest.(check int) "key attempts" 2 !attempts

let test_retry_always_still_requires_replayable_body () =
  Test.with_test_clock @@ fun _sw _clock rt ->
  let attempts, client =
    retry_client
      [|
        (fun () -> retry_response ~headers:[ "Retry-After", "0" ] 503);
        (fun () -> retry_response 200);
      |]
  in
  let request =
    Http.Request.make
      ~body:(Stream (Http.Body.Stream.of_bytes [ Bytes.of_string "x" ]))
      "POST" "https://api.example.test/retry"
  in
  let policy =
    Http.Retry_policy.always ~max_attempts:3
      ~schedule:(Eta.Schedule.spaced Eta.Duration.zero)
      ()
  in
  let response =
    Eta.Runtime.run rt (Http.request_with_retry ~policy client request)
    |> Test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 503 response.status;
  Alcotest.(check int) "attempts" 1 !attempts
