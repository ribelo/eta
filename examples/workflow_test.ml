open Eta

type error =
  [ `Invalid_id of string
  | `Timeout ]
[@@deriving eta_error]

let parse_id = function
  | "" -> Error (`Invalid_id "empty")
  | id -> Ok id

let lookup_user id =
  [%eta.result "user.lookup" (Ok ("user:" ^ id))]

let program raw =
  let open Syntax in
  let* id = Effect.from_result (parse_id raw) in
  let* user =
    lookup_user id
    |> Effect.delay (Duration.ms 10)
    |> Effect.timeout_as (Duration.ms 50) ~on_timeout:`Timeout
  in
  Effect.pure user

let test_success_with_virtual_clock () =
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let run = Eta_test.Async.fork_run sw rt (program "42") in
  Eta_test.Async.yield ();
  Alcotest.(check int) "delay and timeout sleepers" 2
    (Eta_test.Test_clock.sleeper_count clock);
  Eta_test.Test_clock.adjust clock (Duration.ms 10);
  let user = Eta_test.Async.await run |> Eta_test.Expect.expect_ok in
  Alcotest.(check string) "user" "user:42" user

let test_typed_failure () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  Eta_test.Expect.expect_typed_failure
    (Eta.Runtime.run rt (program ""))
    (function
      | `Invalid_id "empty" -> true
      | `Invalid_id _ | `Timeout -> false)

let () =
  Alcotest.run "eta-example-workflow"
    [
      ( "workflow",
        [
          Alcotest.test_case "success with virtual clock" `Quick
            test_success_with_virtual_clock;
          Alcotest.test_case "typed failure" `Quick test_typed_failure;
        ] );
    ]
