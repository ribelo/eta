open Test_eta_http_support

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let find_sub haystack ~needle = find_sub_from haystack ~needle 0

let require_sub haystack ~needle =
  match find_sub haystack ~needle with
  | Some index -> index
  | None -> Alcotest.failf "missing source marker: %s" needle

let find_h1_client_source () =
  let candidates =
    [
      "lib/http/h1/h1_client.ml";
      "../lib/http/h1/h1_client.ml";
      "../../lib/http/h1/h1_client.ml";
      "../../../lib/http/h1/h1_client.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate h1_client.ml from %s" (Sys.getcwd ())

let find_http_client_source () =
  let candidates =
    [
      "lib/http/client/client.ml";
      "../lib/http/client/client.ml";
      "../../lib/http/client/client.ml";
      "../../../lib/http/client/client.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate client.ml from %s" (Sys.getcwd ())

let request_owner_source source =
  let start =
    require_sub source
      ~needle:"let request_owner pool request response_ch release_ch cancel_ch ="
  in
  let finish =
    match find_sub_from source ~needle:"let request_with_pool pool request =" start with
    | Some finish -> finish
    | None -> Alcotest.fail "missing request_owner end marker"
  in
  String.sub source start (finish - start)

let make_h1_source source =
  let start = require_sub source ~needle:"let make_h1 ~sw ~net" in
  let finish =
    match find_sub_from source ~needle:"let make_h1_direct" start with
    | Some finish -> finish
    | None -> Alcotest.fail "missing make_h1 end marker"
  in
  String.sub source start (finish - start)

let test_h1_client_origin_pool_creation_is_fenced () =
  let source = read_file (find_http_client_source ()) in
  let body = make_h1_source source in
  ignore (require_sub body ~needle:"let pools_mutex = Eio.Mutex.create ()" : int);
  ignore (require_sub body ~needle:"with_pools_lock" : int);
  ignore (require_sub body ~needle:"Hashtbl.find_opt pools key" : int);
  ignore (require_sub body ~needle:"Hashtbl.replace pools key pool" : int);
  ignore (require_sub body ~needle:"H1_client.shutdown_pool pool" : int)

let test_client_rejects_cross_domain_use () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Eta_http.Client.make ~sw ~net:(Eio.Stdenv.net stdenv) ()
  in
  let rejected =
    ((Domain.spawn
       [@alert "-do_not_spawn_domains"]
       [@alert "-unsafe_multidomain"])
       (fun () ->
        match Eta_http.Client.stats client with
        | _ -> false
        | exception Invalid_argument msg ->
            Option.is_some (find_sub msg ~needle:"different domain")))
    |> Domain.join
  in
  Alcotest.(check bool) "cross-domain client use rejected" true rejected

let test_h1_pool_marks_undelivered_response_unreusable () =
  let source = read_file (find_h1_client_source ()) in
  let body = request_owner_source source in
  let send =
    require_sub body ~needle:"Channel.try_send response_ch (Ok response)"
  in
  let failed_delivery =
    match
      find_sub_from body
        ~needle:"| `Full | `Closed | `Closed_with_error _ ->" send
    with
    | Some index -> index
    | None -> Alcotest.fail "missing failed response delivery branch"
  in
  let tail = String.sub body failed_delivery (String.length body - failed_delivery) in
  let direct_mark =
    match find_sub tail ~needle:"conn.reusable <- false" with
    | Some _ -> true
    | None -> false
  in
  let helper_mark =
    match find_sub body ~needle:"let abandon_response () =" with
    | None -> false
    | Some helper ->
        Option.is_some
          (find_sub_from body ~needle:"conn.reusable <- false" helper)
        && Option.is_some (find_sub tail ~needle:"abandon_response ()")
  in
  Alcotest.(check bool)
    "failed delivery marks connection unreusable" true
    (direct_mark || helper_mark)

let test_h1_client_request_on_flow_fixed_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/models" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check (option string))
    "content-length" (Some "5")
    (Eta_http.Core.Header.get "content-length" response.headers);
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body)

let test_h1_client_reads_split_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-split-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n";
      `Return "\r\nhe";
      `Return "llo";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/split" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body)

let test_h1_client_decodes_chunked_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-chunked-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return
        "HTTP/1.1 200 OK\r\n\
         Transfer-Encoding: chunked\r\n\
         \r\n\
         4\r\n\
         Wiki\r\n\
         5\r\n\
         pedia\r\n\
         0\r\n\
         X-Trailer: ok\r\n\
         \r\n";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/chunked" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let trailers =
    response.trailers () |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "Wikipedia" (Bytes.to_string body);
  Alcotest.(check (option string))
    "trailer" (Some "ok")
    (Eta_http.Core.Header.get "x-trailer" trailers)

let test_h1_client_caps_close_delimited_body () =
  let flow = Eio_mock.Flow.make "eta-http-h1-close-delimited-cap-flow" in
  let body_chunks =
    List.init 17 (fun _ -> `Return (String.make (64 * 1024) 'x'))
  in
  Eio_mock.Flow.on_read flow
    (`Return "HTTP/1.1 200 OK\r\n\r\n" :: body_chunks);
  let url = Eta_http.Core.Url.of_string "http://example.test/close-delimited" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
  |> expect_body_too_large "close-delimited" ~limit:body_size_cap

let test_h1_client_streaming_request_body_releases () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-request-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  let released = ref 0 in
  let body =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abc"; Bytes.of_string "def" ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/upload" in
  let request : Eta_http.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http.H1.Client.Stream body }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response_body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "response" "ok" (Bytes.to_string response_body);
  Alcotest.(check int) "request body released" 1 !released

let h1_blocking_body ~released () =
  let first = ref true in
  let never, _resolver = Eio.Promise.create () in
  Eta_http.Body.Stream.of_reader
    ~release:(fun () ->
      incr released;
      Eta.Effect.unit)
    (fun () ->
      if !first then (
        first := false;
        Eta.Effect.pure
          (Eta_http.Body.Stream.Chunk (Bytes.of_string (String.make 1024 'x'))))
      else
        Eta.Effect.sync (fun () -> Eio.Promise.await never)
        |> Eta.Effect.map (fun () -> Eta_http.Body.Stream.End))

let h1_timeout_error uri =
  Eta_http.Error.make ~protocol:H1 ~method_:"POST" ~uri
    (Connection_closed { during = Cancellation })

let test_h1_client_cancelled_streaming_request_body_releases () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-cancel-flow" in
  let released = ref 0 in
  let uri = "http://example.test/cancel-upload" in
  let url = Eta_http.Core.Url.of_string uri in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [];
      body = Eta_http.H1.Client.Stream (h1_blocking_body ~released ());
    }
  in
  with_test_clock @@ fun sw clock rt ->
  let timed =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 5)
         ~on_timeout:(h1_timeout_error uri)
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  let rec wait_for_timeout attempts =
    if Eta_test.Test_clock.sleeper_count clock > 0 then ()
    else if attempts = 0 then Alcotest.fail "request timeout was not registered"
    else (
      Eta_test.Async.yield ();
      wait_for_timeout (attempts - 1))
  in
  wait_for_timeout 50;
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 5);
  let result = Eta_test.Async.await result in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Cancellation }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "cancelled body released" 1 !released

let test_h1_client_streaming_request_body_releases_on_write_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-write-fail-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Unix.Unix_error (Unix.EPIPE, "write", "")) ];
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/write-fail" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [];
      body = Eta_http.H1.Client.Stream (h1_blocking_body ~released ());
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Http_request }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "failed write body released" 1 !released

let test_h1_client_streaming_request_body_write_cancellation_propagates () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-write-cancel-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [
      `Return 4096;
      `Return 4096;
      `Raise (Eio.Cancel.Cancelled (Failure "request body write cancelled"));
    ];
  let released = ref 0 in
  let body =
    Eta_http.H1.Client.Rewindable_stream
      {
        length = Some 3;
        make =
          (fun () ->
            Eta_http.Body.Stream.of_bytes
              ~release:(fun () ->
                incr released;
                Eta.Effect.unit)
              [ Bytes.of_string "abc" ]);
      }
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/write-cancel" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Content-Length", "3") ];
      body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  (match Eta_http.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "request write cancellation unexpectedly succeeded"
  | Eta.Exit.Error (Eta.Cause.Interrupt _) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "request write cancellation became typed failure: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause);
  Alcotest.(check int) "cancelled write body released" 1 !released

let test_h1_client_rejects_mismatched_stream_content_length () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-framing-flow" in
  let released = ref 0 in
  let body =
    Eta_http.H1.Client.Rewindable_stream
      {
        length = Some 6;
        make =
          (fun () ->
            Eta_http.Body.Stream.of_bytes
              ~release:(fun () ->
                incr released;
                Eta.Effect.unit)
              [ Bytes.of_string "abcdef" ]);
      }
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/framing" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Content-Length", "3") ];
      body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Header_invalid { reason }; _ } ->
        contains reason "Content-Length"
    | _ -> false);
  Alcotest.(check int) "rejected stream body released" 1 !released

let test_h1_client_rejects_unknown_stream_content_length () =
  let flow = Eio_mock.Flow.make "eta-http-h1-unknown-stream-content-length" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  let released = ref 0 in
  let body =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abcdef" ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/framing" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Content-Length", "3") ];
      body = Eta_http.H1.Client.Stream body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  (match
     Eta.Runtime.run rt (Eta_http.H1.Client.request_on_flow ~flow request)
   with
  | Eta.Exit.Error
      (Eta.Cause.Fail { Eta_http.Error.kind = Header_invalid { reason }; _ }) ->
      Alcotest.(check bool)
        "mentions Content-Length" true
        (contains reason "Content-Length")
  | Eta.Exit.Ok _ ->
      Alcotest.fail
        "unknown-length stream with caller Content-Length was sent"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp Eta_http.Error.pp)
        cause);
  Alcotest.(check int) "stream released after rejection" 1 !released

let test_h1_client_rejects_unknown_stream_unsupported_transfer_encoding () =
  let flow = Eio_mock.Flow.make "eta-http-h1-unknown-stream-unsupported-te" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  let body = Eta_http.Body.Stream.of_bytes [ Bytes.of_string "abcdef" ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/framing" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Transfer-Encoding", "gzip") ];
      body = Eta_http.H1.Client.Stream body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta.Runtime.run rt (Eta_http.H1.Client.request_on_flow ~flow request)
  with
  | Eta.Exit.Error
      (Eta.Cause.Fail { Eta_http.Error.kind = Header_invalid { reason }; _ }) ->
      Alcotest.(check bool)
        "mentions Transfer-Encoding" true
        (contains reason "Transfer-Encoding")
  | Eta.Exit.Ok _ ->
      Alcotest.fail
        "unknown-length stream with unsupported Transfer-Encoding was sent"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp Eta_http.Error.pp)
        cause

let expect_h1_transfer_encoding_failure label = function
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          Eta_http.Error.kind =
            Connection_protocol_violation { kind = "transfer_encoding"; _ };
          _;
        }) ->
      ()
  | Eta.Exit.Ok _ ->
      Alcotest.failf "%s: expected transfer-encoding failure" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: unexpected failure: %a" label
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_h1_client_rejects_non_final_chunked_transfer_encoding () =
  let flow =
    Eio_mock.Flow.make "eta-http-h1-response-non-final-chunked-te"
  in
  Eio_mock.Flow.on_read flow
    [
      `Return
        "HTTP/1.1 200 OK\r\n\
         Transfer-Encoding: chunked, gzip\r\n\
         \r\n\
         3\r\n\
         abc\r\n\
         0\r\n\
         \r\n";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/te" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta.Runtime.run rt (Eta_http.H1.Client.request_on_flow ~flow request)
  with
  | Eta.Exit.Error _ as exit ->
      expect_h1_transfer_encoding_failure "response head" exit
  | Eta.Exit.Ok response ->
      Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
      |> expect_h1_transfer_encoding_failure "response body"

let test_h1_client_custom_release_on_write_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-write-release-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Unix.Unix_error (Unix.EPIPE, "write", "")) ];
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/write-fail" in
  let request : Eta_http.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      ~flow request
    |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Http_request }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "released" 1 !released

let test_h1_client_custom_release_on_response_header_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-read-release-flow" in
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/read-fail" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      ~flow request
    |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Http_response }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "released" 1 !released

let test_h1_client_head_ignores_chunked_body_headers () =
  let flow = Eio_mock.Flow.make "eta-http-h1-head-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/head" in
  let request : Eta_http.H1.Client.request =
    { method_ = "HEAD"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "empty body" 0 (Bytes.length body)

let test_h1_client_skips_100_continue () =
  let flow = Eio_mock.Flow.make "eta-http-h1-continue-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/continue" in
  let headers =
    Eta_http.Core.Header.unsafe_of_list [ "Expect", "100-continue" ]
  in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers;
      body = Eta_http.H1.Client.Fixed [ Bytes.of_string "abc" ];
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ok" (Bytes.to_string body)

let test_h1_pool_reuses_healthy_idle_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none";
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo";
    ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.unit
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "one TCP open" 1 stats.Eta.Pool.opened;
  Alcotest.(check int) "idle" 1 stats.idle;
  Alcotest.(check int) "health check on reuse" 1 !health_checks

let test_h1_pool_rejects_overread_bytes_before_reuse () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-overread-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-pool-overread-first" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-pool-overread-second" in
  Eio_mock.Flow.on_read first_flow
    [
      `Return
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\noneHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo";
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nbad";
    ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.unit
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool-overread" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "overread connection was not reused" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "overread connection was closed" 1 stats.closed;
  Alcotest.(check int) "overread connection was health rejected" 1 stats.health_rejected;
  Alcotest.(check int) "idle" 1 stats.idle;
  Alcotest.(check int) "custom health check skipped for fenced connection" 0
    !health_checks

let test_h1_pool_rejects_unhealthy_idle_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-unhealthy-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-pool-first-flow" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-pool-second-flow" in
  Eio_mock.Flow.on_read first_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none" ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.fail
      (Eta_http.Error.make ~protocol:H1 ~method_:"*" ~uri:"http://example.test"
         (Connection_closed { during = Pool }))
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "two TCP opens" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "one rejected" 1 stats.health_rejected;
  Alcotest.(check int) "one closed" 1 stats.closed;
  Alcotest.(check int) "health check called" 1 !health_checks

let test_h1_pool_holds_checkout_until_body_eof () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-release-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-release-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/release" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body);
  let closed_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after eof" 0 closed_stats.active;
  Alcotest.(check int) "idle after eof" 1 closed_stats.idle

let test_h1_pool_discard_releases_checkout () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-discard-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-discard-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndrop" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/discard" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  Eta_http.Body.Stream.discard response.body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let closed_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after discard" 0 closed_stats.active;
  Alcotest.(check int) "idle after discard" 1 closed_stats.idle

let test_h1_pool_discarded_body_does_not_poison_next_response () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-discard-poison-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-pool-discard-poison-first" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-pool-discard-poison-second" in
  Eio_mock.Flow.on_read first_flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n";
      `Return "poison";
    ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nsafe" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/discard-poison" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  let health_check _flow = Eta.Effect.unit in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let first =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Eta_http.Body.Stream.discard first.body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let second =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let body =
    Eta_http.Body.Stream.read_all second.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "second response body" "safe" body;
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "discarded connection was not reused" 2 stats.opened;
  Alcotest.(check int) "discarded connection was closed" 1 stats.closed

let test_h1_pool_oversized_fixed_body_does_not_poison_next_response () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-oversized-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-pool-oversized-first" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-pool-oversized-second" in
  Eio_mock.Flow.on_read first_flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n";
      `Return "ABCDHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbad!";
    ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\ns" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/oversized" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  let health_check _flow = Eta.Effect.unit in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~max_response_body_bytes:1
      ~health_check ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let first =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Eta_http.Body.Stream.read_all first.body
  |> Eta.Runtime.run rt
  |> expect_body_too_large "oversized fixed body" ~limit:1;
  let released_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after oversized failure" 0 released_stats.active;
  let second =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let body =
    Eta_http.Body.Stream.read_all second.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "second response body" "s" body;
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "oversized connection was not reused" 2 stats.opened;
  Alcotest.(check int) "oversized connection was closed" 1 stats.closed

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "%s did not become true" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let test_h1_pool_request_cancellation_releases_checkout () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-cancel-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-cancel-flow" in
  let never = Eta_test.Async.unresolved () in
  Eio_mock.Flow.on_read flow [ `Await never ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/cancel" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let logger = Eta.Logger.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~logger:(Eta.Logger.as_capability logger) ()
  in
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let timed =
    let timeout_error =
      Eta_http.Error.make ~protocol:H1 ~method_:"GET"
        ~uri:"http://example.test/cancel"
        (Response_header_timeout { timeout_ms = Some 1 })
    in
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 1) ~on_timeout:timeout_error
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  wait_until "request active" (fun () ->
      (Eta_http.H1.Client.pool_stats pool).active = 1);
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await result with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Response_header_timeout { timeout_ms = Some 1 }; _ }) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "cancelled request unexpectedly succeeded"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cancellation result: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause);
  wait_until "request checkout released" (fun () ->
      (Eta_http.H1.Client.pool_stats pool).active = 0);
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active released" 0 stats.active;
  for _ = 1 to 5 do
    Eta_test.Async.yield ()
  done;
  let daemon_failures =
    Eta.Logger.dump logger
    |> List.filter (fun record ->
           String.equal record.Eta.Logger.body "eta.daemon.failure")
  in
  Alcotest.(check int) "cancellation logged no daemon failure" 0
    (List.length daemon_failures)

(* GREEN TEST: server sends Connection: close; the connection is marked
   non-reusable and the health check rejects it on next checkout,
   forcing a new TCP open. *)
let test_h1_pool_connection_close_opens_new_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-close-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-close-first-flow" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-close-second-flow" in
  Eio_mock.Flow.on_read first_flow
    [ `Return "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\none" ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/close" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "two TCP opens" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "one health rejected" 1 stats.health_rejected;
  Alcotest.(check int) "one closed" 1 stats.closed

(* Non-EOF exceptions from Eio.Flow.single_read while reading a response body
   must surface as a typed Connection_closed (Http_response) failure, not as a
   raw Cause.Die defect, and the release function must still run. *)
let test_body_stream_read_exception_leaks_release () =
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/leak" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  let flow = Eio_mock.Flow.make "eta-http-h1-leak-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel";
      `Raise (Failure "read truncated") ];
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      ~flow request
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  (* First read succeeds, second read raises raw exception. *)
  (match Eta_http.Body.Stream.read response.body |> Eta.Runtime.run rt with
  | Eta.Exit.Ok (Some chunk) ->
      Alcotest.(check string) "first chunk" "hel" (Bytes.to_string chunk)
  | other -> Alcotest.failf "unexpected first read: %a" Fmt.(Dump.option string)
                 (match other with Eta.Exit.Ok x -> Option.map Bytes.to_string x | _ -> None));
  (* Second read raises Failure("read truncated"); it must be translated into a
     typed connection-closed failure, not leak as a raw defect. *)
  (match Eta_http.Body.Stream.read response.body |> Eta.Runtime.run rt with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Connection_closed { during = Http_response }; _ }) ->
      ()
  | Eta.Exit.Error (Eta.Cause.Die _) ->
      Alcotest.fail "body read exception escaped as defect"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected typed body read failure");
  Alcotest.(check int) "release called despite read exception" 1 !released

let test_h1_response_head_read_exception_is_typed_and_releases () =
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/head" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "GET";
      url;
      headers = [];
      body = Eta_http.H1.Client.Empty;
    }
  in
  let flow = Eio_mock.Flow.make "eta-http-h1-head-read-raises" in
  Eio_mock.Flow.on_read flow [ `Raise (Failure "head read boom") ];

  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let exit =
    Eta_http.H1.Client.request_on_flow
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      ~flow request
    |> Eta.Runtime.run rt
  in

  Alcotest.(check int) "release called" 1 !released;
  match exit with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          Eta_http.Error.kind =
            Eta_http.Error.Connection_closed
              { during = Eta_http.Error.Http_response };
          _;
        }) ->
      ()
  | Eta.Exit.Error (Eta.Cause.Die _) ->
      Alcotest.fail "raw read exception escaped as defect"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause
  | Eta.Exit.Ok _ ->
      Alcotest.fail "expected typed connection failure"

let test_h1_body_read_exception_is_typed () =
  let url = Eta_http.Core.Url.of_string "http://example.test/body" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "GET";
      url;
      headers = [];
      body = Eta_http.H1.Client.Empty;
    }
  in
  let flow = Eio_mock.Flow.make "eta-http-h1-body-read-raises" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel";
      `Raise (Failure "body read boom");
    ];

  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in

  ignore
    (Eta_http.Body.Stream.read response.body
     |> Eta.Runtime.run rt
     |> Eta_test.Expect.expect_ok);

  match Eta.Runtime.run rt (Eta_http.Body.Stream.read response.body) with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          Eta_http.Error.kind =
            Eta_http.Error.Connection_closed
              { during = Eta_http.Error.Http_response };
          _;
        }) ->
      ()
  | Eta.Exit.Error (Eta.Cause.Die _) ->
      Alcotest.fail "body read exception escaped as defect"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause
  | Eta.Exit.Ok _ ->
      Alcotest.fail "expected typed body read failure"

let test_client_make_h1_request_path () =
  let net = Eio_mock.Net.make "eta-http-client-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-client-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  with_test_clock @@ fun sw _clock rt ->
  let client = Eta_http.Client.make_h1 ~sw ~net () in
  let request = Eta_http.Request.make "GET" "http://example.test/models" in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ok" (Bytes.to_string body)
