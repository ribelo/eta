module S = Eta_http.Server
module Service = Eta_http_service

let run eff =
  Eta_test.with_test_clock @@ fun _sw _clock rt -> Eta_eio.Runtime.run rt eff

let run_ok eff =
  match run eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp S.Error.pp) cause

let expect_bad_request = function
  | Eta.Exit.Error (Eta.Cause.Fail { S.Error.kind = Bad_request _; _ }) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Bad_request, got %a" (Eta.Cause.pp S.Error.pp)
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected Bad_request"

let expect_body_too_large = function
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { S.Error.kind = Request_body_too_large { limit; length }; _ }) ->
      Alcotest.(check int) "limit" 4 limit;
      Alcotest.(check int) "length" 5 length
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Request_body_too_large, got %a"
        (Eta.Cause.pp S.Error.pp) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected Request_body_too_large"

let request ?(method_ = "GET") ?(target = "/")
    ?(headers = Eta_http.Core.Header.empty) ?(body = "") () =
  let path, query = S.Request.split_target target in
  let body =
    if String.equal body "" then S.Body.empty ()
    else
      let chunks = ref [ Bytes.of_string body ] in
      S.Body.of_reader
        (fun () ->
          match !chunks with
          | [] -> Eta.Effect.pure None
          | chunk :: rest ->
              chunks := rest;
              Eta.Effect.pure (Some chunk))
  in
  {
    S.Request.id = lazy "req-test";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "example.test";
    method_;
    target;
    path;
    query;
    headers;
    body;
    trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "conn-test";
  }

let body_string response =
  match S.Response.body response with
  | S.Response.Body.Empty -> ""
  | Fixed chunks -> Bytes.to_string (Bytes.concat Bytes.empty chunks)
  | Stream _ -> Alcotest.fail "expected fixed body"

let text ?status value = Eta.Effect.pure (S.Response.text ?status value)

let test_router_routing_404_405 () =
  let router = Service.Router.create () in
  Service.Router.add_exn router ~methods:[ "GET" ] "/items/{id}" (fun req ->
      let id = Option.get (Service.Req.param req "id") in
      text
        (Printf.sprintf "id=%s route=%s\n" id
           (Service.Req.route_pattern req)));
  Service.Router.add_exn router ~methods:[ "POST" ] "/items" (fun _req ->
      text ~status:201 "created\n");
  Service.Router.add_any_exn router "/health" (fun req ->
      text ("health " ^ Service.Req.method_ req ^ "\n"));
  let handler = Service.Router.compile router in
  let get_item = run_ok (handler (request ~target:"/items/42" ())) in
  Alcotest.(check int) "GET item status" 200 (S.Response.status get_item);
  Alcotest.(check string) "GET item body" "id=42 route=/items/{id}\n"
    (body_string get_item);
  let post_item =
    run_ok (handler (request ~method_:"POST" ~target:"/items" ()))
  in
  Alcotest.(check int) "POST status" 201 (S.Response.status post_item);
  let any =
    run_ok (handler (request ~method_:"PATCH" ~target:"/health" ()))
  in
  Alcotest.(check string) "any body" "health PATCH\n" (body_string any);
  let method_miss =
    run_ok (handler (request ~method_:"DELETE" ~target:"/items/42" ()))
  in
  Alcotest.(check int) "405 status" 405 (S.Response.status method_miss);
  Alcotest.(check (option string)) "allow" (Some "GET")
    (Eta_http.Core.Header.get "allow" (S.Response.headers method_miss));
  let path_miss = run_ok (handler (request ~target:"/missing" ())) in
  Alcotest.(check int) "404 status" 404 (S.Response.status path_miss)

let test_router_registration_failures () =
  let router = Service.Router.create () in
  Alcotest.(check bool) "empty method set" true
    (match Service.Router.add router ~methods:[] "/x" (fun _ -> text "x") with
    | Error (Empty_method_set _) -> true
    | _ -> false);
  Service.Router.add_exn router ~methods:[ "GET" ] "/x" (fun _ -> text "x");
  Alcotest.(check bool) "duplicate method" true
    (match
       Service.Router.add router ~methods:[ "GET" ] "/x" (fun _ -> text "x")
     with
    | Error (Duplicate_route { method_ = Some "GET"; _ }) -> true
    | _ -> false);
  Alcotest.(check bool) "ambiguous any" true
    (match Service.Router.add_any router "/x" (fun _ -> text "x") with
    | Error (Ambiguous_any_route _) -> true
    | _ -> false);
  Alcotest.(check bool) "invalid pattern" true
    (match Service.Router.add router ~methods:[ "GET" ] "/bad/{}" (fun _ -> text "x") with
    | Error (Invalid_pattern _) -> true
    | _ -> false)

let test_query_extractors_decode_and_preserve_duplicates () =
  let router = Service.Router.create () in
  Service.Router.add_exn router ~methods:[ "GET" ] "/query" (fun req ->
      let open Eta.Syntax in
      let* query = Service.Extractors.Query.all req in
      let tags = Service.Extractors.Query.get_all "tag" query in
      let q = Option.value ~default:"" (Service.Extractors.Query.get "q" query) in
      let encoded =
        Option.value ~default:"" (Service.Extractors.Query.get "encoded" query)
      in
      text (String.concat "|" (q :: encoded :: tags) ^ "\n"));
  let handler = Service.Router.compile router in
  let response =
    run_ok
      (handler
         (request
            ~target:"/query?q=a+b&encoded=a%2Fb&tag=one&tag=two" ()))
  in
  Alcotest.(check string) "decoded query" "a b|a/b|one|two\n"
    (body_string response);
  expect_bad_request
    (run
       (handler
          (request ~target:"/query?bad=%" ())))

let test_param_and_json_extractors () =
  let router = Service.Router.create () in
  Service.Router.add_exn router ~methods:[ "GET" ] "/items/{id}"
    (Service.Extractors.route1
       (Service.Extractors.Param.int "id")
       (fun id -> text (string_of_int (id + 1) ^ "\n")));
  Service.Router.add_exn router ~methods:[ "POST" ] "/json" (fun req ->
      let decode = function
        | `Assoc fields -> (
            match List.assoc_opt "name" fields with
            | Some (`String name) -> Ok name
            | _ -> Error "name is required")
        | _ -> Error "object is required"
      in
      let open Eta.Syntax in
      let* name = Service.Extractors.json_body ~max_bytes:64 decode req in
      text ~status:201 (name ^ "\n"));
  let handler = Service.Router.compile router in
  let response = run_ok (handler (request ~target:"/items/41" ())) in
  Alcotest.(check string) "param int" "42\n" (body_string response);
  expect_bad_request (run (handler (request ~target:"/items/nope" ())));
  let response =
    run_ok
      (handler
         (request ~method_:"POST" ~target:"/json"
            ~body:{|{"name":"eta"}|} ()))
  in
  Alcotest.(check int) "json status" 201 (S.Response.status response);
  Alcotest.(check string) "json body" "eta\n" (body_string response);
  expect_bad_request
    (run
       (handler
          (request ~method_:"POST" ~target:"/json" ~body:"not-json" ())));
  expect_bad_request
    (run
       (handler
          (request ~method_:"POST" ~target:"/json" ~body:{|{"x":1}|} ())))

let test_body_text_enforces_max_bytes () =
  let router = Service.Router.create () in
  Service.Router.add_exn router ~methods:[ "POST" ] "/body" (fun req ->
      let open Eta.Syntax in
      let* body = Service.Extractors.body_text ~max_bytes:4 req in
      text body);
  let handler = Service.Router.compile router in
  expect_body_too_large
    (run (handler (request ~method_:"POST" ~target:"/body" ~body:"abcde" ())))

let test_json_response_helper () =
  let response = Service.Json.response ~newline:true (`Assoc [ ("ok", `Bool true) ]) in
  Alcotest.(check int) "status" 200 (S.Response.status response);
  Alcotest.(check (option string)) "content-type"
    (Some Service.Json.content_type)
    (Eta_http.Core.Header.get "content-type" (S.Response.headers response));
  Alcotest.(check string) "body" ({|{"ok":true}|} ^ "\n")
    (body_string response)

let layer log label inner request =
  log := (label ^ ">") :: !log;
  let open Eta.Syntax in
  let+ response = inner request in
  log := ("<" ^ label) :: !log;
  response

let test_middleware_plain_onion_order () =
  let log = ref [] in
  let handler =
    (fun _ -> text "ok\n")
    |> layer log "A"
    |> layer log "B"
    |> layer log "C"
  in
  ignore (run_ok (handler (request ())));
  Alcotest.(check (list string)) "order"
    [ "C>"; "B>"; "A>"; "<A"; "<B"; "<C" ]
    (List.rev !log)

let test_middleware_request_id_access_log_admission_auth_cors () =
  let logs = ref [] in
  let verified = ref None in
  let semaphore = Eta.Semaphore.make ~permits:1 in
  let headers =
    Eta_http.Core.Header.unsafe_of_list [ ("authorization", "Bearer secret") ]
  in
  let handler =
    (fun _ -> text "ok\n")
    |> Service.Middleware.bearer_auth ~verify:(fun ~token _request ->
           verified := token;
           Eta.Effect.unit)
    |> Service.Middleware.admission semaphore
    |> Service.Middleware.access_log ~log:(fun entry -> logs := entry :: !logs)
    |> Service.Middleware.request_id ()
    |> Service.Middleware.cors ()
  in
  let response = run_ok (handler (request ~headers ())) in
  Alcotest.(check string) "auth token" "secret" (Option.get !verified);
  Alcotest.(check int) "admission released" 1 (Eta.Semaphore.available semaphore);
  Alcotest.(check (option string)) "request id" (Some "req-test")
    (Eta_http.Core.Header.get "x-request-id" (S.Response.headers response));
  Alcotest.(check (option string)) "cors" (Some "*")
    (Eta_http.Core.Header.get "access-control-allow-origin"
       (S.Response.headers response));
  (match !logs with
  | [ entry ] ->
      Alcotest.(check (option int)) "logged status" (Some 200) entry.status;
      Alcotest.(check string) "logged path" "/" entry.path
  | _ -> Alcotest.fail "expected one access log entry");
  let options =
    run_ok (handler (request ~method_:"OPTIONS" ~target:"/anything" ()))
  in
  Alcotest.(check int) "cors preflight" 204 (S.Response.status options)

let test_middleware_timeout_typed_failure () =
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let handler =
    Service.Middleware.timeout (Eta.Duration.ms 50) (fun _request ->
        Eta.Effect.delay (Eta.Duration.seconds 60) (text "late\n"))
  in
  let promise = Eta_test.Async.fork_run sw rt (handler (request ())) in
  Eta_test.Async.yield ();
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 50);
  match Eta_test.Async.await promise with
  | Eta.Exit.Error
      (Eta.Cause.Fail { S.Error.kind = Handler_timeout { timeout_ms }; _ }) ->
      Alcotest.(check (option int)) "timeout" (Some 50) timeout_ms
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Handler_timeout, got %a"
        (Eta.Cause.pp S.Error.pp) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected timeout"

let () =
  Alcotest.run "eta-http-service"
    [
      ( "router",
        [
          Alcotest.test_case "routing 404 405" `Quick test_router_routing_404_405;
          Alcotest.test_case "registration failures" `Quick
            test_router_registration_failures;
        ] );
      ( "extractors",
        [
          Alcotest.test_case "query decoding" `Quick
            test_query_extractors_decode_and_preserve_duplicates;
          Alcotest.test_case "params and json" `Quick test_param_and_json_extractors;
          Alcotest.test_case "body max bytes" `Quick
            test_body_text_enforces_max_bytes;
        ] );
      ( "json",
        [ Alcotest.test_case "response helper" `Quick test_json_response_helper ]
      );
      ( "middleware",
        [
          Alcotest.test_case "plain onion order" `Quick
            test_middleware_plain_onion_order;
          Alcotest.test_case "helpers" `Quick
            test_middleware_request_id_access_log_admission_auth_cors;
          Alcotest.test_case "timeout" `Quick test_middleware_timeout_typed_failure;
        ] );
    ]
