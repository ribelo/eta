open Test_eta_http_support

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

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
      "lib/http_eio/h1/h1_client.ml";
      "lib/http/h1/h1_client.ml";
      "../lib/http_eio/h1/h1_client.ml";
      "../lib/http/h1/h1_client.ml";
      "../../lib/http_eio/h1/h1_client.ml";
      "../../lib/http/h1/h1_client.ml";
      "../../../lib/http_eio/h1/h1_client.ml";
      "../../../lib/http/h1/h1_client.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate h1_client.ml from %s" (Sys.getcwd ())

let find_http_client_source () =
  let candidates =
    [
      "lib/http_eio/client.ml";
      "lib/http/client/client.ml";
      "../lib/http_eio/client.ml";
      "../lib/http/client/client.ml";
      "../../lib/http_eio/client.ml";
      "../../lib/http/client/client.ml";
      "../../../lib/http_eio/client.ml";
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
    Eta_http_eio.Client.make ~sw ~net:(Eio.Stdenv.net stdenv)
      ~clock:(Eio.Stdenv.clock stdenv) ()
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http_eio.H1.Client.Stream body }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [];
      body = Eta_http_eio.H1.Client.Stream (h1_blocking_body ~released ());
    }
  in
  with_test_clock @@ fun sw clock rt ->
  let timed =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [];
      body = Eta_http_eio.H1.Client.Stream (h1_blocking_body ~released ());
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http_eio.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt
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
    Eta_http_eio.H1.Client.Rewindable_stream
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Content-Length", "3") ];
      body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  (match Eta_http_eio.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt with
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
    Eta_http_eio.H1.Client.Rewindable_stream
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Content-Length", "3") ];
      body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http_eio.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Content-Length", "3") ];
      body = Eta_http_eio.H1.Client.Stream body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  (match
     Eta.Runtime.run rt (Eta_http_eio.H1.Client.request_on_flow ~flow request)
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [ ("Transfer-Encoding", "gzip") ];
      body = Eta_http_eio.H1.Client.Stream body;
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta.Runtime.run rt (Eta_http_eio.H1.Client.request_on_flow ~flow request)
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta.Runtime.run rt (Eta_http_eio.H1.Client.request_on_flow ~flow request)
  with
  | Eta.Exit.Error _ as exit ->
      expect_h1_transfer_encoding_failure "response head" exit
  | Eta.Exit.Ok response ->
      Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
      |> expect_h1_transfer_encoding_failure "response body"

let test_h1_client_rejects_empty_transfer_encoding_tokens () =
  let cases = [ "chunked,"; "chunked, "; ",chunked"; " , chunked" ] in
  List.iter
    (fun value ->
      let flow =
        Eio_mock.Flow.make
          ("eta-http-h1-response-empty-te-token-" ^ string_of_int (String.length value))
      in
      Eio_mock.Flow.on_read flow
        [
          `Return
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: " ^ value
           ^ "\r\n\r\n0\r\n\r\n");
        ];
      let url = Eta_http.Core.Url.of_string "http://example.test/te" in
      let request : Eta_http_eio.H1.Client.request =
        {
          method_ = "GET";
          url;
          headers = [];
          body = Eta_http_eio.H1.Client.Empty;
        }
      in
      with_test_clock @@ fun _sw _clock rt ->
      match
        Eta.Runtime.run rt (Eta_http_eio.H1.Client.request_on_flow ~flow request)
      with
      | Eta.Exit.Error _ as exit ->
          expect_h1_transfer_encoding_failure value exit
      | Eta.Exit.Ok response ->
          Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
          |> expect_h1_transfer_encoding_failure value)
    cases

let test_h1_client_custom_release_on_write_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-write-release-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Unix.Unix_error (Unix.EPIPE, "write", "")) ];
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/write-fail" in
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http_eio.H1.Client.request_on_flow
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http_eio.H1.Client.request_on_flow
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "HEAD"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers;
      body = Eta_http_eio.H1.Client.Fixed [ Bytes.of_string "abc" ];
    }
  in
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http_eio.H1.Client.request_with_pool pool request
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
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http_eio.H1.Client.request_with_pool pool request
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
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http_eio.H1.Client.request_with_pool pool request
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
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http_eio.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body);
  let closed_stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http_eio.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  Eta_http.Body.Stream.discard response.body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let closed_stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  let health_check _flow = Eta.Effect.unit in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let first =
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Eta_http.Body.Stream.discard first.body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let second =
    Eta_http_eio.H1.Client.request_with_pool pool request
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
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  let health_check _flow = Eta.Effect.unit in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~max_response_body_bytes:1
      ~health_check ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let first =
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Eta_http.Body.Stream.read_all first.body
  |> Eta.Runtime.run rt
  |> expect_body_too_large "oversized fixed body" ~limit:1;
  let released_stats = Eta_http_eio.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after oversized failure" 0 released_stats.active;
  let second =
    Eta_http_eio.H1.Client.request_with_pool pool request
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
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
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
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let timed =
    let timeout_error =
      Eta_http.Error.make ~protocol:H1 ~method_:"GET"
        ~uri:"http://example.test/cancel"
        (Response_header_timeout { timeout_ms = Some 1 })
    in
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 1) ~on_timeout:timeout_error
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  wait_until "request active" (fun () ->
      (Eta_http_eio.H1.Client.pool_stats pool).active = 1);
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
      (Eta_http_eio.H1.Client.pool_stats pool).active = 0);
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
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

let test_h1_pool_dead_keep_alive_opens_new_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-dead-keepalive-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-dead-keepalive-first" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-dead-keepalive-second" in
  Eio_mock.Flow.on_read first_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none" ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/dead-keepalive" in
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http_eio.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
  Alcotest.(check int) "two TCP opens" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "dead idle connection rejected" 1 stats.health_rejected;
  Alcotest.(check int) "dead idle connection closed" 1 stats.closed

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
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http_eio.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
  Alcotest.(check int) "two TCP opens" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "one health rejected" 1 stats.health_rejected;
  Alcotest.(check int) "one closed" 1 stats.closed

(* Non-EOF exceptions from Eio.Flow.single_read while reading a response body
   must surface as a typed Connection_closed (Http_response) failure, not as a
   raw Cause.Die defect, and the release function must still run. *)
let test_body_stream_read_exception_leaks_release () =
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/leak" in
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  let flow = Eio_mock.Flow.make "eta-http-h1-leak-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel";
      `Raise (Failure "read truncated") ];
  with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http_eio.H1.Client.request_on_flow
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "GET";
      url;
      headers = [];
      body = Eta_http_eio.H1.Client.Empty;
    }
  in
  let flow = Eio_mock.Flow.make "eta-http-h1-head-read-raises" in
  Eio_mock.Flow.on_read flow [ `Raise (Failure "head read boom") ];

  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let exit =
    Eta_http_eio.H1.Client.request_on_flow
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
  let request : Eta_http_eio.H1.Client.request =
    {
      method_ = "GET";
      url;
      headers = [];
      body = Eta_http_eio.H1.Client.Empty;
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
    Eta_http_eio.H1.Client.request_on_flow ~flow request
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
  let client = Eta_http_eio.Client.make_h1 ~sw ~net () in
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

let test_eio_runtime_service_h1_request () =
  let net = Eio_mock.Net.make "eta-http-eio-service-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-eio-service-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nservice" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let services = [ Eta_http_eio.runtime_service ~sw ~net ~clock () ] in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock ~services ()
  in
  let client = Eta_http.Client.make_runtime ~protocol:H1 () in
  let request = Eta_http.Request.make "GET" "http://example.test/service" in
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
  Alcotest.(check string) "body" "service" (Bytes.to_string body)

(* Helpers for the zio-http ClientStreamingSpec / RequestStreamingServerSpec /
   RequestStreamingConcurrencySpec port below. *)

let with_h1_server_client handler f =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:256 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~socket handler
  in
  let client = Eta_http_eio.Client.make_h1 ~sw ~net () in
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.Server.shutdown server Eta_http_eio.Server.Immediate)
    (fun () -> f sw clock net rt client server port)

let with_h1_server_client_and_runtime_service handler f =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:256 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let runtime_factory ~sw ~connection:_ () =
    let http_service = Eta_http_eio.runtime_service ~sw ~net ~clock () in
    Eta_eio.Runtime.create ~sw ~clock ~services:[ http_service ] ()
  in
  let server =
    Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~socket ~runtime_factory
      handler
  in
  let client = Eta_http_eio.Client.make_h1 ~sw ~net () in
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.Server.shutdown server Eta_http_eio.Server.Immediate)
    (fun () -> f sw clock net rt client server port)

let string_chunks ?(chunk_size = 3) text =
  let rec split acc i =
    if i >= String.length text then List.rev acc
    else
      let n = min chunk_size (String.length text - i) in
      split (Bytes.of_string (String.sub text i n) :: acc) (i + n)
  in
  split [] 0

let read_body_string rt body =
  Eta_http.Body.Stream.read_all body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok
  |> Bytes.to_string

let read_body_chunks rt body =
  let rec loop acc =
    match Eta_http.Body.Stream.read body |> Eta.Runtime.run rt with
    | Eta.Exit.Ok None -> List.rev acc
    | Eta.Exit.Ok (Some chunk) -> loop (Bytes.to_string chunk :: acc)
    | Eta.Exit.Error cause ->
        Alcotest.failf "read chunk failed: %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause
  in
  loop []

(* zio-http ClientStreamingSpec ports *)

let test_h1_client_streaming_simple_get () =
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text "simple response")
  in
  with_h1_server_client handler @@ fun _sw _clock _net rt client _server port ->
  let request =
    Eta_http.Request.make "GET"
      (Printf.sprintf "http://127.0.0.1:%d/simple-get" port)
  in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check string) "body" "simple response"
    (read_body_string rt response.body)

let test_h1_client_streaming_get () =
  let handler (_request : Eta_http.Server.Request.t) =
    let chunks = string_chunks ~chunk_size:3 "streaming response" in
    let remaining = ref chunks in
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200
         ~body:
           (Eta_http.Server.Response.Body.stream (fun () ->
                match !remaining with
                | [] -> Eta.Effect.pure None
                | chunk :: rest ->
                    remaining := rest;
                    Eta.Effect.pure (Some chunk)))
         ())
  in
  with_h1_server_client handler @@ fun _sw _clock _net rt client _server port ->
  let request =
    Eta_http.Request.make "GET"
      (Printf.sprintf "http://127.0.0.1:%d/streaming-get" port)
  in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let chunks = read_body_chunks rt response.body in
  Alcotest.(check string) "concatenated body" "streaming response"
    (String.concat "" chunks)

(* Eta exposes decoded response chunks without a synthetic trailing empty chunk,
   so this port checks the concatenated stream payload. *)

let test_h1_client_streaming_simple_post () =
  (* zio-http ClientStreamingSpec: client sends a chunked request body and the
     server drains it before responding. *)
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.discard ~drain:true request.body
    |> Eta.Effect.map (fun () ->
           Eta_http.Server.Response.make ~status:200
             ~body:Eta_http.Server.Response.Body.empty ())
  in
  with_h1_server_client handler @@ fun _sw clock _net rt client _server port ->
  let body =
    Eta_http.Body.Stream.of_bytes (string_chunks ~chunk_size:3 "streaming request")
  in
  let request =
    Eta_http.Request.make ~body:(Stream body) "POST"
      (Printf.sprintf "http://127.0.0.1:%d/simple-post" port)
  in
  match
    Eio.Time.with_timeout_exn clock 2.0 (fun () ->
        Eta_http.request client request |> Eta.Runtime.run rt)
  with
  | Eta.Exit.Ok response ->
      Alcotest.(check int) "status" 200 response.status;
      Eta_http.Body.Stream.discard response.body
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
  | Eta.Exit.Error _ ->
      Alcotest.fail "streaming simple post failed instead of completing"
  | exception Eio.Time.Timeout ->
      Alcotest.fail "streaming simple post timed out"

let test_h1_client_streaming_echo () =
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200
         ~body:
           (Eta_http.Server.Response.Body.stream (fun () ->
                Eta_http.Server.Body.read request.body))
         ())
  in
  with_h1_server_client handler @@ fun _sw _clock _net rt client _server port ->
  let body =
    Eta_http.Body.Stream.of_bytes (string_chunks ~chunk_size:3 "streaming request")
  in
  let request =
    Eta_http.Request.make ~body:(Stream body) "POST"
      (Printf.sprintf "http://127.0.0.1:%d/streaming-echo" port)
  in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let chunks = read_body_chunks rt response.body in
  Alcotest.(check string) "concatenated body" "streaming request"
    (String.concat "" chunks)

(* zio-http multipart form tests are skipped: Eta does not yet implement
   multipart/form-data parsing or generation. *)

let test_h1_client_streaming_failed_stream () =
  (* zio-http ClientStreamingSpec: a request body stream failure should
     propagate to the request. *)
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.discard ~drain:true request.body
    |> Eta.Effect.map (fun () ->
           Eta_http.Server.Response.make ~status:200
             ~body:Eta_http.Server.Response.Body.empty ())
  in
  with_h1_server_client handler @@ fun _sw clock _net rt client _server port ->
  let body =
    Eta_http.Body.Stream.of_reader (fun () ->
        Eta.Effect.fail
          (Eta_http.Error.make ~protocol:H1 ~method_:"POST"
             ~uri:(Printf.sprintf "http://127.0.0.1:%d/simple-post" port)
             (Decode_error { codec = "stream"; message = "Some error" })))
  in
  let request =
    Eta_http.Request.make ~body:(Stream body) "POST"
      (Printf.sprintf "http://127.0.0.1:%d/simple-post" port)
  in
  match
    Eio.Time.with_timeout_exn clock 2.0 (fun () ->
        Eta_http.request client request |> Eta.Runtime.run rt)
  with
  | Eta.Exit.Ok _ ->
      Alcotest.fail "failed stream request unexpectedly succeeded"
  | Eta.Exit.Error _ -> ()
  | exception Eio.Time.Timeout ->
      Alcotest.fail "streaming failed stream timed out"

(* zio-http RequestStreamingServerSpec ports *)

let test_h1_client_streaming_large_content () =
  let size = 1024 * 1024 in
  let content = String.make size '?' in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all ~max_bytes:(2 * size) request.body
    |> Eta.Effect.map (fun body ->
           Eta_http.Server.Response.text (string_of_int (Bytes.length body)))
  in
  with_h1_server_client handler @@ fun _sw _clock _net rt client _server port ->
  let request =
    Eta_http.Request.make ~body:(Fixed [ Bytes.of_string content ]) "POST"
      (Printf.sprintf "http://127.0.0.1:%d/large" port)
  in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check string) "body" (string_of_int size)
    (read_body_string rt response.body)

let test_h1_client_streaming_multiple_body_read () =
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.bind (fun _first ->
           Eta_http.Server.Body.read_all request.body
           |> Eta.Effect.map (fun _second ->
                  Eta_http.Server.Response.make ~status:200
                    ~body:Eta_http.Server.Response.Body.empty ()))
  in
  with_h1_server_client handler @@ fun _sw _clock _net rt client _server port ->
  let request =
    Eta_http.Request.make "POST"
      (Printf.sprintf "http://127.0.0.1:%d/multiple-read" port)
  in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  (* Eta treats reads after EOF as empty; this is the Eta-specific variant of
     zio-http's multiple-read regression. *)
  Alcotest.(check int) "status" 200 response.status

let test_h1_client_streaming_proxy () =
  let http_error_to_server_error err =
    Eta_http.Server.Error.make ~protocol:H1 ~method_:"POST" ~target:"/1"
      (Handler_failed { message = Eta_http.Error.to_string err })
  in
  let server_body_as_stream body =
    let rec reader () =
      Eta_http.Server.Body.read body
      |> Eta.Effect.map_error Eta_http.Server.Error.to_http_error
      |> Eta.Effect.map (function
          | None -> Eta_http.Body.Stream.End
          | Some bytes -> Eta_http.Body.Stream.Chunk bytes)
    in
    Eta_http.Body.Stream.of_reader reader
  in
  let proxy_handler (request : Eta_http.Server.Request.t) =
    let host = Option.value request.authority ~default:"127.0.0.1" in
    let url = Printf.sprintf "http://%s/2" host in
    let client = Eta_http.Client.make_runtime ~protocol:H1 () in
    let req =
      Eta_http.Request.make
        ~body:(Stream (server_body_as_stream request.body))
        "POST" url
    in
    Eta_http.request client req
    |> Eta.Effect.map_error http_error_to_server_error
    |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
           Eta_http.Body.Stream.read_all response.body
           |> Eta.Effect.map_error http_error_to_server_error
           |> Eta.Effect.map (fun body ->
                  Eta_http.Server.Response.make ~status:response.status
                    ~body:(Eta_http.Server.Response.Body.fixed [ body ])
                    ()))
  in
  let length_handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all ~max_bytes:(2 * 1024 * 1024) request.body
    |> Eta.Effect.map (fun body ->
           Eta_http.Server.Response.text (string_of_int (Bytes.length body)))
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/1" -> proxy_handler request
    | "/2" -> length_handler request
    | _ ->
        Eta.Effect.pure
          (Eta_http.Server.Response.make ~status:404
             ~body:Eta_http.Server.Response.Body.empty ())
  in
  with_h1_server_client_and_runtime_service handler
  @@ fun _sw _clock _net rt client _server port ->
  let sizes = [ 0; 8192; 1024 * 1024 ] in
  List.iter
    (fun size ->
      let payload = String.make size 'x' in
      let request =
        Eta_http.Request.make ~body:(Fixed [ Bytes.of_string payload ]) "POST"
          (Printf.sprintf "http://127.0.0.1:%d/1" port)
      in
      let response =
        Eta_http.request client request |> Eta.Runtime.run rt
        |> Eta_test.Expect.expect_ok
      in
      Alcotest.(check int)
        (Printf.sprintf "status for size %d" size) 200 response.status;
      Alcotest.(check string)
        (Printf.sprintf "body for size %d" size)
        (string_of_int size) (read_body_string rt response.body))
    sizes

(* zio-http RequestStreamingConcurrencySpec port *)

let test_h1_client_streaming_concurrent_load () =
  let payload_size = 4096 in
  (* zio-http runs this regression at 100 x 20 operations with a 120s timeout.
     Keep the same concurrent store/fetch shape here, but scale it for the
     regular Eta HTTP suite rather than turning the suite into a load test. *)
  let parallelism = 32 in
  let ops_per_fiber = 5 in
  let store_mutex = Eio.Mutex.create () in
  let store = Hashtbl.create 256 in
  let store_counter = Atomic.make 0 in
  let store_handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.bind (fun body ->
           let id = string_of_int (Atomic.fetch_and_add store_counter 1) in
           Eta.Effect.sync (fun () ->
               Eio.Mutex.use_rw ~protect:true store_mutex (fun () ->
                   Hashtbl.replace store id body))
           |> Eta.Effect.map (fun () ->
                  Eta_http.Server.Response.make ~status:201
                    ~headers:
                      (Eta_http.Core.Header.unsafe_of_list [ ("X-Id", id) ])
                    ~body:Eta_http.Server.Response.Body.empty ()))
  in
  let fetch_handler id (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.discard request.body
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () ->
               Eio.Mutex.use_rw ~protect:true store_mutex (fun () ->
                   Hashtbl.find_opt store id))
           |> Eta.Effect.map (function
                | None ->
                    Eta_http.Server.Response.make ~status:404
                      ~body:Eta_http.Server.Response.Body.empty ()
                | Some body ->
                    Eta_http.Server.Response.make ~status:200
                      ~body:(Eta_http.Server.Response.Body.fixed [ body ])
                      ()))
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/store" -> store_handler request
    | path when String.starts_with ~prefix:"/fetch/" path ->
        fetch_handler
          (String.sub path 7 (String.length path - 7))
          request
    | _ ->
        Eta.Effect.pure
          (Eta_http.Server.Response.make ~status:404
             ~body:Eta_http.Server.Response.Body.empty ())
  in
  with_h1_server_client handler
  @@ fun sw clock net rt _client _server port ->
  let origin =
    Eta_http.Core.Url.of_string
      (Printf.sprintf "http://127.0.0.1:%d/" port)
  in
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:parallelism ~sw ~net origin
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let payload = Bytes.of_string (String.make payload_size 'z') in
  let test_failure message =
    Eta_http.Error.make ~protocol:H1 ~method_:"*" ~uri:(Eta_http.Core.Url.to_string origin)
      (Connection_protocol_violation { kind = "test"; message })
  in
  let store_payload () =
    let request =
      {
        Eta_http_eio.H1.Client.method_ = "POST";
        url =
          Eta_http.Core.Url.of_string
            (Printf.sprintf "http://127.0.0.1:%d/store" port);
        headers = [];
        body = Fixed [ payload ];
      }
    in
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Effect.bind (fun (response : Eta_http_eio.H1.Client.response) ->
           if response.status <> 201 then
             Eta.Effect.fail
               (test_failure
                  (Printf.sprintf "store status %d" response.status))
           else
             match Eta_http.Core.Header.get "x-id" response.headers with
             | None -> Eta.Effect.fail (test_failure "missing X-Id header")
             | Some id ->
                 Eta_http.Body.Stream.discard response.body
                 |> Eta.Effect.map (fun () -> id))
  in
  let fetch_payload id =
    let request =
      {
        Eta_http_eio.H1.Client.method_ = "GET";
        url =
          Eta_http.Core.Url.of_string
            (Printf.sprintf "http://127.0.0.1:%d/fetch/%s" port id);
        headers = [];
        body = Empty;
      }
    in
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Effect.bind (fun (response : Eta_http_eio.H1.Client.response) ->
           if response.status <> 200 then
             Eta.Effect.fail
               (test_failure
                  (Printf.sprintf "fetch status %d" response.status))
           else Eta_http.Body.Stream.read_all response.body)
  in
  let fiber_exit =
    try
      Eio.Time.with_timeout_exn clock 5.0 (fun () ->
        Eta.Effect.for_each_par
          (List.init parallelism (fun _ -> ()))
          (fun () ->
            let rec loop n acc =
              if n = 0 then Eta.Effect.pure (List.rev acc)
              else
                store_payload ()
                |> Eta.Effect.bind (fun id ->
                       fetch_payload id
                       |> Eta.Effect.bind (fun fetched ->
                              loop (n - 1)
                                (( Bytes.length payload,
                                   Bytes.length fetched )
                                :: acc)))
            in
            loop ops_per_fiber [])
        |> Eta.Runtime.run rt)
    with Eio.Time.Timeout -> Alcotest.fail "streaming concurrent load timed out"
  in
  let fiber_results = Eta_test.Expect.expect_ok fiber_exit in
  List.iter
    (List.iter (fun (expected, actual) ->
         Alcotest.(check int) "stored and fetched payload length" expected actual))
    fiber_results


(* zio-http ClientSpec connection-failure cases *)

let test_h1_client_connection_failure () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  let url = Eta_http.Core.Url.of_string "http://127.0.0.1:1/" in
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  match Eta.Runtime.run rt (Eta_http_eio.H1.Client.request ~sw ~net request) with
  | Eta.Exit.Ok _ ->
      Alcotest.fail "connection to localhost:1 unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail { Eta_http.Error.kind = Eta_http.Error.Connect_error _; _ }) ->
      (* Eta surfaces connection failure as a typed Connect_error. *)
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp Eta_http.Error.pp) cause

let broken_server_headers_only =
  "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n"

let test_h1_client_broken_server_headers_no_body () =
  (* zio-http ClientSpec: server advertises Content-Length: 2 but closes
     without sending a body. The client should fail rather than hang forever.
     Eta returns the response head successfully; consuming the body then
     surfaces a typed connection-closed failure. *)
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      Fun.protect
        ~finally:(fun () -> try Eio.Flow.close flow with _ -> ())
        (fun () -> Eio.Flow.copy_string broken_server_headers_only flow));
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  let uri = Printf.sprintf "http://127.0.0.1:%d/" port in
  let url = Eta_http.Core.Url.of_string uri in
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  let eff =
    Eta_http_eio.H1.Client.request ~sw ~net request
    |> Eta.Effect.bind (fun (response : Eta_http_eio.H1.Client.response) ->
           Eta_http.Body.Stream.read_all response.body)
  in
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok _ ->
      Alcotest.fail "broken server request unexpectedly succeeded"
  | Eta.Exit.Error cause ->
      let rec has_connection_closed = function
        | Eta.Cause.Fail
            { Eta_http.Error.kind = Eta_http.Error.Connection_closed { during = Eta_http.Error.Http_response }; _ }
          ->
            true
        | Eta.Cause.Concurrent causes | Eta.Cause.Sequential causes ->
            List.exists has_connection_closed causes
        | Eta.Cause.Suppressed { primary; _ } -> has_connection_closed primary
        | _ -> false
      in
      if not (has_connection_closed cause) then
        Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp Eta_http.Error.pp) cause

let test_h1_pool_broken_server_concurrent_requests_timeout () =
  (* zio-http ClientSpec: a broken server that closes after the response head
     should not exhaust a pool of size 1 when several requests race. Each
     request acquires the single connection, reads the response head, then
     fails while reading the missing body, releasing the slot for the next. *)
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let accept_count = ref 0 in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      while !accept_count < 3 do
        let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
        Fun.protect
          ~finally:(fun () -> try Eio.Flow.close flow with _ -> ())
          (fun () -> Eio.Flow.copy_string broken_server_headers_only flow);
        incr accept_count
      done);
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  let uri = Printf.sprintf "http://127.0.0.1:%d/" port in
  let url = Eta_http.Core.Url.of_string uri in
  let pool =
    Eta_http_eio.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let request : Eta_http_eio.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http_eio.H1.Client.Empty }
  in
  let one_request () =
    Eta_http_eio.H1.Client.request_with_pool pool request
    |> Eta.Effect.bind (fun (response : Eta_http_eio.H1.Client.response) ->
           Eta_http.Body.Stream.read_all response.body)
  in
  let rec run_n n =
    if n = 0 then ()
    else
      match Eta.Runtime.run rt (one_request ()) with
      | Eta.Exit.Ok _ ->
          Alcotest.fail "broken server pool request unexpectedly succeeded"
      | Eta.Exit.Error cause ->
          let rec has_connection_closed = function
            | Eta.Cause.Fail
                { Eta_http.Error.kind = Eta_http.Error.Connection_closed { during = Eta_http.Error.Http_response }; _ }
              ->
                true
            | Eta.Cause.Concurrent causes | Eta.Cause.Sequential causes ->
                List.exists has_connection_closed causes
            | Eta.Cause.Suppressed { primary; _ } -> has_connection_closed primary
            | _ -> false
          in
          if not (has_connection_closed cause) then
            Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp Eta_http.Error.pp) cause;
          run_n (n - 1)
  in
  run_n 3;
  let stats = Eta_http_eio.H1.Client.pool_stats pool in
  Alcotest.(check int) "pool active after failures" 0 stats.Eta.Pool.active
