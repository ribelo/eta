open Test_eta_http_support

let wait_for_sleepers clock expected =
  let rec loop attempts =
    if Eta_test.Test_clock.sleeper_count clock >= expected then ()
    else if attempts = 0 then
      Alcotest.failf "expected %d sleepers, got %d" expected
        (Eta_test.Test_clock.sleeper_count clock)
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let timeout_error uri ms =
  Eta_http.Error.make ~method_:"GET" ~uri
    (Total_request_timeout { timeout_ms = Some ms })

let assert_timeout_only expected = function
  | Eta.Exit.Error (Eta.Cause.Fail error) ->
      Alcotest.(check bool) "timeout error" true (error = expected)
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected only timeout, got %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause
  | Eta.Exit.Ok response ->
      Alcotest.failf "request unexpectedly succeeded with status %d"
        response.Eta_http.Response.status

let test_retry_delay_timeout_cancels_before_next_attempt () =
  with_test_clock @@ fun sw clock rt ->
  let attempts, client =
    retry_client [| (fun () -> retry_response 503) |]
  in
  let uri = "http://example.test/cancel-delay" in
  let request = Eta_http.Request.make "GET" uri in
  let policy =
    Eta_http.Retry_policy.make ~max_attempts:100
      ~schedule:(Eta.Schedule.fixed (Eta.Duration.ms 500))
      ~respect_retry_after:false ()
  in
  let expected = timeout_error uri 200 in
  let timed =
    Eta_http.Client.request_with_retry ~policy client request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 200) ~on_timeout:expected
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  wait_for_sleepers clock 2;
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 200);
  assert_timeout_only expected (Eta_test.Async.await result);
  Alcotest.(check int) "attempts before timeout" 1 !attempts

let test_retry_after_timeout_cancels_before_next_attempt () =
  with_test_clock @@ fun sw clock rt ->
  let attempts, client =
    retry_client
      [| (fun () ->
            retry_response ~headers:[ ("Retry-After", "3600") ] 503)
      |]
  in
  let uri = "http://example.test/retry-after-timeout" in
  let request = Eta_http.Request.make "GET" uri in
  let expected = timeout_error uri 300 in
  let timed =
    Eta_http.Client.request_with_retry client request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 300) ~on_timeout:expected
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  wait_for_sleepers clock 2;
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 300);
  assert_timeout_only expected (Eta_test.Async.await result);
  Alcotest.(check int) "attempts before timeout" 1 !attempts

let test_retry_after_far_future_date_is_capped () =
  let far_future = "Fri, 31 Dec 9999 23:59:59 GMT" in
  match Eta_http.Retry_policy.retry_after ~now_s:0.0 far_future with
  | None -> Alcotest.fail "far-future HTTP-date was rejected"
  | Some delay ->
      Alcotest.(check int) "cap"
        (Eta.Duration.to_ms Eta_http.Retry_policy.default_max_retry_after)
        (Eta.Duration.to_ms delay)

let test_two_parameter_schedule_http_signatures () =
  let schedule : (unit, int) Eta.Schedule.t = Eta.Schedule.recurs 1 in
  let (_ : Eta_http.Retry_policy.t) =
    Eta_http.Retry_policy.make ~schedule ()
  in
  let (_ : Eta_http.Retry_policy.t) =
    Eta_http.Retry_policy.always ~schedule ()
  in
  ()

let test_lowercase_get_is_not_default_retryable () =
  Alcotest.(check bool)
    "method classifier" false
    (Eta_http.Idempotency.method_is_idempotent "get");
  with_test_clock @@ fun _sw _clock rt ->
  let attempts, client =
    retry_client [| (fun () -> retry_response 503) |]
  in
  let policy =
    Eta_http.Retry_policy.make ~max_attempts:2
      ~schedule:(Eta.Schedule.fixed Eta.Duration.zero)
      ~respect_retry_after:false ()
  in
  let request =
    Eta_http.Request.make "get" "http://example.test/lowercase-get"
  in
  let response =
    Eta_http.Client.request_with_retry ~policy client request
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 503 response.Eta_http.Response.status;
  Alcotest.(check int) "attempts" 1 !attempts
