module Exa = Eta_exa
module H = Eta_http

let key = Exa.api_key "secret-key"
let string_opt = Alcotest.(option string)

let request operation = Exa.request ~api_key:key operation |> Result.get_ok

let body = function
  | H.Request.Fixed [ value ] -> Bytes.to_string value
  | Empty | Fixed _ | Stream _ | Rewindable_stream _ ->
      Alcotest.fail "expected one fixed body"

let test_core_requests () =
  let search = request (Exa.Search {|{"query":"eta"}|}) in
  Alcotest.(check string) "search method" "POST" search.method_;
  Alcotest.(check string)
    "search URI" "https://api.exa.ai/search" search.uri;
  Alcotest.(check string) "search body" {|{"query":"eta"}|} (body search.body);
  Alcotest.(check string_opt)
    "API key header" (Some "secret-key")
    (H.Core.Header.get "x-api-key" search.headers);
  let contents = request (Exa.Contents "{}") in
  Alcotest.(check string)
    "contents URI" "https://api.exa.ai/contents" contents.uri;
  let context = request (Exa.Code_context "{}") in
  Alcotest.(check string)
    "context URI" "https://api.exa.ai/context" context.uri

let test_agent_requests () =
  let get = request (Exa.Agent_get { id = "run /?" }) in
  Alcotest.(check string)
    "encoded id" "https://api.exa.ai/agent/runs/run%20%2F%3F" get.uri;
  Alcotest.(check string_opt)
    "GET has no content type" None
    (H.Core.Header.get "content-type" get.headers);
  let list =
    request (Exa.Agent_list { limit = Some 20; cursor = Some "next /" })
  in
  Alcotest.(check string)
    "list query"
    "https://api.exa.ai/agent/runs?limit=20&cursor=next%20%2F" list.uri;
  let cancel = request (Exa.Agent_cancel { id = "run-1" }) in
  Alcotest.(check string) "cancel method" "POST" cancel.method_;
  Alcotest.(check string)
    "cancel URI" "https://api.exa.ai/agent/runs/run-1/cancel" cancel.uri;
  Alcotest.(check string_opt)
    "cancel has no content type" None
    (H.Core.Header.get "content-type" cancel.headers);
  let events =
    request
      (Exa.Agent_events
         {
           id = "run-1";
           limit = Some 5;
           cursor = Some "cursor";
           last_event_id = Some "event-9";
         })
  in
  Alcotest.(check string)
    "events URI"
    "https://api.exa.ai/agent/runs/run-1/events?limit=5&cursor=cursor"
    events.uri;
  Alcotest.(check string_opt)
    "event header" (Some "event-9")
    (H.Core.Header.get "last-event-id" events.headers)

let test_invalid_requests () =
  let expect_invalid = function
    | Error (Exa.Invalid_request _) -> ()
    | Error (Exa.Http _) -> Alcotest.fail "expected request validation failure"
    | Ok _ -> Alcotest.fail "expected invalid request"
  in
  expect_invalid (Exa.request ~api_key:key (Exa.Search ""));
  expect_invalid (Exa.request ~api_key:key (Exa.Agent_get { id = " " }));
  expect_invalid
    (Exa.request ~api_key:key
       (Exa.Agent_list { limit = None; cursor = Some "" }));
  expect_invalid
    (Exa.request ~api_key:key
       (Exa.Agent_list { limit = Some 101; cursor = None }))

let test_run_preserves_status_and_body () =
  let response =
    H.Response.make ~status:429
      ~body:(H.Body.Stream.of_bytes [ Bytes.of_string {|{"error":"rate"}|} ])
      ()
  in
  let client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun _ -> Eta.Effect.pure response)
      ~stats:(fun () -> Eta.Effect.pure None)
      ~shutdown:(fun () -> Eta.Effect.unit)
  in
  Eta_test.with_test_clock (fun _sw _clock runtime ->
      match
        Exa.run client ~api_key:key (Exa.Search "{}")
        |> Eta.Runtime.run runtime
      with
      | Eta.Exit.Ok response ->
          Alcotest.(check int) "status" 429 response.status;
          Alcotest.(check string) "body" {|{"error":"rate"}|} response.body
      | Eta.Exit.Error cause ->
          Alcotest.failf "unexpected failure: %a"
            (Eta.Cause.pp (fun formatter error ->
                 Format.pp_print_string formatter (Exa.error_message error)))
            cause)

let () =
  Alcotest.run "eta_exa"
    [
      ( "request",
        [
          Alcotest.test_case "core endpoints" `Quick test_core_requests;
          Alcotest.test_case "agent endpoints" `Quick test_agent_requests;
          Alcotest.test_case "invalid values" `Quick test_invalid_requests;
          Alcotest.test_case "raw response" `Quick
            test_run_preserves_status_and_body;
        ] );
    ]
