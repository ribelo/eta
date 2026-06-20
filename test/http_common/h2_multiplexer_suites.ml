module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let expect_ok = function
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a"
          (Eta.Cause.pp Eta_http.Error.pp)
          cause

  let h2_iovecs_to_string iovecs =
    let len = Eta_http_h2.Iovec.lengthv iovecs in
    let bytes = Bytes.create len in
    let dst_off = ref 0 in
    List.iter
      (fun ({ Eta_http_h2.Iovec.buffer; off; len } :
              Bigstringaf.t Eta_http_h2.Iovec.t) ->
        Bigstringaf.blit_to_bytes buffer ~src_off:off bytes ~dst_off:!dst_off
          ~len;
        dst_off := !dst_off + len)
      iovecs;
    Bytes.unsafe_to_string bytes

  let h2_feed_client client data =
    let rec loop off =
      if off < String.length data then (
        let len = String.length data - off in
        let buffer = Bigstringaf.of_string ~off ~len data in
        let consumed =
          Eta_http_h2.Connection.read client buffer ~off:0 ~len
        in
        if consumed <= 0 then Alcotest.fail "client consumed no h2 bytes";
        loop (off + consumed))
    in
    loop 0

  let h2_feed_server server data =
    let rec loop off =
      if off < String.length data then (
        let len = String.length data - off in
        let buffer = Bigstringaf.of_string ~off ~len data in
        let consumed =
          Eta_http_h2.Connection.read server buffer ~off:0 ~len
        in
        if consumed <= 0 then Alcotest.fail "server consumed no h2 bytes";
        loop (off + consumed))
    in
    loop 0

  let rec h2_drain_server_output server acc =
    match Eta_http_h2.Connection.next_write_operation server with
    | Write iovecs ->
        let data = h2_iovecs_to_string iovecs in
        Eta_http_h2.Connection.report_write_result server
          (`Ok (String.length data));
        h2_drain_server_output server (data :: acc)
    | Yield -> String.concat "" (List.rev acc)
    | Close _ ->
        Eta_http_h2.Connection.report_write_result server `Closed;
        String.concat "" (List.rev acc)

  let h2_drain_client_to_server client server =
    match Eta_http_h2.Connection.next_write_operation client with
    | Write iovecs ->
        let data = h2_iovecs_to_string iovecs in
        Eta_http_h2.Connection.report_write_result client
          (`Ok (String.length data));
        h2_feed_server server data;
        true
    | Yield -> false
    | Close _ ->
        Eta_http_h2.Connection.report_write_result client `Closed;
        false

  let h2_drain_server_to_client server client =
    match Eta_http_h2.Connection.next_write_operation server with
    | Write iovecs ->
        let data = h2_iovecs_to_string iovecs in
        Eta_http_h2.Connection.report_write_result server
          (`Ok (String.length data));
        h2_feed_client client data;
        true
    | Yield -> false
    | Close _ ->
        Eta_http_h2.Connection.report_write_result server `Closed;
        false

  let h2_pump_pair ?(limit = 10_000) client server =
    let rec loop remaining =
      if remaining <= 0 then Alcotest.fail "h2 pump did not quiesce"
      else
        let client_progress = h2_drain_client_to_server client server in
        let server_progress = h2_drain_server_to_client server client in
        if client_progress || server_progress then loop (remaining - 1)
    in
    loop limit

  let h2_eta_iovecs_to_string = h2_iovecs_to_string

  let h2_feed_eta_client = h2_feed_client

  let h2_drain_eta_client_to_server = h2_drain_client_to_server

  let h2_drain_server_to_eta_client = h2_drain_server_to_client

  let h2_pump_eta_client_server = h2_pump_pair

  let h2_pp_client_error (error : Eta_http_h2.Connection.error) =
    Format.asprintf "protocol_error:%a:%s" Eta_http_h2.Error_code.pp_hum
      error.error_code error.message

  type h2_mux_result = {
    mutable mux_status : int option;
    mux_body : Buffer.t;
    mutable mux_eof : bool;
    mutable mux_stream_errors : string list;
    mutable mux_client_errors : string list;
    mutable mux_stream : Eta_http_eio.H2.Multiplexer.stream option;
    mutable mux_release : Eta_http_h2.Stream_state.release option;
  }

  let h2_mux_result () =
    {
      mux_status = None;
      mux_body = Buffer.create 128;
      mux_eof = false;
      mux_stream_errors = [];
      mux_client_errors = [];
      mux_stream = None;
      mux_release = None;
    }

  let h2_mux_create ?max_concurrent ?config result () =
    Eta_http_eio.H2.Multiplexer.create ?max_concurrent ?config
      ~error_handler:(fun error ->
        result.mux_client_errors <-
          h2_pp_client_error error :: result.mux_client_errors)
      ()

  let h2_schedule_mux_body mux result stream body =
    let rec loop () =
      Eta_http_h2.Body.Reader.schedule_read body
        ~on_eof:(fun () ->
          Eta_http_eio.H2.Multiplexer.mark_complete mux stream;
          result.mux_eof <- true)
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string result.mux_body (Bigstringaf.substring bs ~off ~len);
          loop ())
    in
    loop ()

  let h2_method_to_string = function
    | `GET -> "GET"
    | `HEAD -> "HEAD"
    | `POST -> "POST"
    | `PUT -> "PUT"
    | `DELETE -> "DELETE"
    | `CONNECT -> "CONNECT"
    | `OPTIONS -> "OPTIONS"
    | `TRACE -> "TRACE"
    | `PATCH -> "PATCH"
    | `Other method_ -> method_

  let h2_core_request ?(meth = "GET") ?(target = "/")
      ?(authority = "api.example.test") () :
      Eta_http_h2.Connection.Client.request =
    { meth; scheme = Some "https"; authority = Some authority; path = target; headers = [] }

  let h2_open_mux_request ?(meth = `GET) ?body ?(target = "/") ?(tag = 0)
      mux result =
    let request = h2_core_request ~meth:(h2_method_to_string meth) ~target () in
    match
      Eta_http_eio.H2.Multiplexer.request mux ~tag request
        ~error_handler:(fun stream error ->
          result.mux_stream <- Some stream;
          result.mux_stream_errors <-
            h2_pp_client_error error :: result.mux_stream_errors)
        ~response_handler:(fun stream response response_body ->
          result.mux_stream <- Some stream;
          result.mux_status <- Some response.status;
          h2_schedule_mux_body mux result stream response_body)
    with
    | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
        Error `Admission_rejected
    | Error Eta_http_eio.H2.Multiplexer.Connection_closed -> Error `Connection_closed
    | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
        Error (`Request_failed message)
    | Ok opened ->
        result.mux_stream <- Some opened.stream;
        (match body with
        | None -> ()
        | Some body ->
            ignore
              (Eta_http_h2.Body.Writer.write_string opened.request_body body));
        Eta_http_h2.Body.Writer.close opened.request_body;
        Ok opened

  let h2_opened label = function
    | Ok opened -> opened
    | Error `Admission_rejected -> Alcotest.failf "%s rejected by admission" label
    | Error `Connection_closed -> Alcotest.failf "%s rejected by closed connection" label
    | Error (`Request_failed message) ->
        Alcotest.failf "%s failed before open: %s" label message

  let h2_stream_of_result label result =
    match result.mux_stream with
    | Some stream -> stream
    | None -> Alcotest.failf "%s did not record stream" label

  let h2_response_body label = function
    | Some body -> body
    | None -> Alcotest.failf "%s did not receive response body" label

  let h2_response_writer label = function
    | Some body -> body
    | None -> Alcotest.failf "%s did not install response writer" label

  let h2_server_response ?(headers = []) ?(body = `String "") status :
      Eta_http_h2.Connection.Server.response =
    { status; headers; body; trailers = Lazy.from_val [] }

  let h2_create_server ?config request_handler =
    Eta_http_h2.Connection.Server.create ?config ~request_handler
      ~error_handler:(fun error ->
        Alcotest.failf "unexpected h2 server error: %a %s"
          Eta_http_h2.Error_code.pp_hum error.error_code error.message)
      ()

  let h2_server_read_body reqd ~on_done =
    let body = Eta_http_h2.Connection.Server.Reqd.request_body reqd in
    let buffer = Buffer.create 4096 in
    let rec loop () =
      Eta_http_h2.Body.Reader.schedule_read body
        ~on_eof:(fun () -> on_done (Buffer.contents buffer))
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string buffer (Bigstringaf.substring bs ~off ~len);
          loop ())
    in
    loop ()

  let h2_body_pump_effect client server =
    Eta.Effect.sync (fun () ->
        let client_progress = h2_drain_eta_client_to_server client server in
        let server_progress = h2_drain_server_to_eta_client server client in
        if client_progress || server_progress then Eta_http_eio.H2.Multiplexer.Read 1
        else Eta_http_eio.H2.Multiplexer.Eof 0)

  let h2_body_closed_error =
    Eta_http.Error.make ~protocol:Eta_http.Error.H2 ~method_:"GET"
      ~uri:"https://api.example.test/"
      (Eta_http.Error.Connection_closed
         { during = Eta_http.Error.Http_response })

  let h2_open_streaming_body mux client server held_writer body_ref =
    let request : Eta_http_h2.Connection.Client.request =
      {
        meth = "GET";
        scheme = Some "https";
        authority = Some "api.example.test";
        path = "/stream";
        headers = [];
      }
    in
    let opened =
      Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
        ~error_handler:(fun _ error ->
          Alcotest.failf "unexpected h2 stream error: %s"
            (h2_pp_client_error error))
        ~response_handler:(fun stream response body ->
          Alcotest.(check int) "status" 200 response.status;
          body_ref :=
            Some
              (Eta_http_eio.H2.Multiplexer.body_stream
                 ~closed_error:h2_body_closed_error
                 ~pump:(fun () -> h2_body_pump_effect client server)
                 mux stream body))
    in
    let opened =
      match opened with
      | Ok opened -> opened
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
          Alcotest.fail "streaming body rejected by admission"
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "streaming body saw closed connection"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "streaming body request failed: %s" message
    in
    Eta_http_h2.Body.Writer.close opened.request_body;
    h2_pump_eta_client_server client server;
    h2_response_writer "streaming body" !held_writer

  let test_h2_body_stream_releases_on_eof () =
    let held_writer = ref None in
    let server =
      h2_create_server (fun reqd ->
          held_writer :=
            Some
              (Eta_http_h2.Connection.Server.Reqd.respond_with_streaming reqd
                 (h2_server_response 200)))
    in
    let mux = h2_mux_create (h2_mux_result ()) () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let body_ref = ref None in
    let writer = h2_open_streaming_body mux client server held_writer body_ref in
    ignore (Eta_http_h2.Body.Writer.write_string writer "hello");
    Eta_http_h2.Body.Writer.close writer;
    B.with_test_clock @@ fun _ctx _clock rt ->
    let body =
      Eta_http.Body.Stream.read_all (h2_response_body "eof" !body_ref)
      |> B.run rt |> expect_ok
    in
    Alcotest.(check string) "body" "hello" (Bytes.to_string body);
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active" 0 stats.active;
    Alcotest.(check int) "live" 0 stats.live;
    Alcotest.(check int) "completed" 1 stats.completed;
    Alcotest.(check int) "local resets" 0 stats.local_resets

  let test_h2_body_stream_reads_inline_data_after_header_pump () =
    let body_ref = ref None in
    let server =
      h2_create_server (fun reqd ->
          Eta_http_h2.Connection.Server.Reqd.respond_with_string reqd
            (h2_server_response ~body:(`String "hello-inline") 404)
            "hello-inline")
    in
    let mux = h2_mux_create (h2_mux_result ()) () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let request =
      h2_core_request ~target:"/inline" ()
    in
    let opened =
      Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
        ~error_handler:(fun _ error ->
          Alcotest.failf "unexpected h2 stream error: %s"
            (h2_pp_client_error error))
        ~response_handler:(fun stream response body ->
          Alcotest.(check int) "status" 404 response.status;
          body_ref :=
            Some
              (Eta_http_eio.H2.Multiplexer.body_stream
                 ~closed_error:h2_body_closed_error
                 ~pump:(fun () -> h2_body_pump_effect client server)
                 mux stream body))
    in
    let opened =
      match opened with
      | Ok opened -> opened
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
          Alcotest.fail "inline body rejected by admission"
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "inline body saw closed connection"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "inline body request failed: %s" message
    in
    Eta_http_h2.Body.Writer.close opened.request_body;
    h2_pump_pair client server;
    B.with_test_clock @@ fun _ctx _clock rt ->
    let body =
      Eta_http.Body.Stream.read_all (h2_response_body "inline" !body_ref)
      |> B.run rt |> expect_ok
    in
    Alcotest.(check string) "body" "hello-inline" (Bytes.to_string body);
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active" 0 stats.active;
    Alcotest.(check int) "completed" 1 stats.completed

  let test_h2_multiplexer_delivers_response_trailers () =
    let body_ref = ref None in
    let trailers_ref = ref None in
    let server =
      h2_create_server (fun reqd ->
          let response_body =
            Eta_http_h2.Connection.Server.Reqd.respond_with_streaming reqd
              (h2_server_response
                 ~headers:[ "content-type", "application/grpc+proto" ]
                 200)
          in
          ignore
            (Eta_http_h2.Body.Writer.write_string response_body
               "\000\000\000\000\005hello");
          Eta_http_h2.Connection.Server.Reqd.schedule_trailers reqd
            [ "grpc-status", "0"; "grpc-message", "" ];
          Eta_http_h2.Body.Writer.close response_body)
    in
    let mux = h2_mux_create (h2_mux_result ()) () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let request =
      h2_core_request ~meth:"POST" ~target:"/grpc.Service/Unary" ()
    in
    let opened =
      Eta_http_eio.H2.Multiplexer.request mux ~tag:1
        ~trailers_handler:(fun trailers ->
          trailers_ref := Some trailers)
        request
        ~error_handler:(fun _ error ->
          Alcotest.failf "unexpected h2 stream error: %s"
            (h2_pp_client_error error))
        ~response_handler:(fun stream response body ->
          Alcotest.(check int) "status" 200 response.status;
          body_ref :=
            Some
              (Eta_http_eio.H2.Multiplexer.body_stream
                 ~closed_error:h2_body_closed_error
                 ~pump:(fun () -> h2_body_pump_effect client server)
                 mux stream body))
    in
    let opened =
      match opened with
      | Ok opened -> opened
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
          Alcotest.fail "trailers request rejected by admission"
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "trailers request saw closed connection"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "trailers request failed: %s" message
    in
    Eta_http_h2.Body.Writer.close opened.request_body;
    h2_pump_pair client server;
    let early_trailers =
      match !trailers_ref with
      | Some trailers -> trailers
      | None -> Alcotest.fail "trailers were not delivered by END_STREAM"
    in
    B.with_test_clock @@ fun _ctx _clock rt ->
    let body =
      Eta_http.Body.Stream.read_all (h2_response_body "trailers" !body_ref)
      |> B.run rt |> expect_ok
    in
    Alcotest.(check string) "raw grpc body" "\000\000\000\000\005hello"
      (Bytes.to_string body);
    Alcotest.(check (option string)) "grpc status" (Some "0")
      (Eta_http.Core.Header.get "grpc-status" early_trailers);
    Alcotest.(check (option string)) "grpc message" (Some "")
      (Eta_http.Core.Header.get "grpc-message" early_trailers)

  let test_h2_body_stream_discard_releases_active_stream () =
    let held_writer = ref None in
    let server =
      h2_create_server (fun reqd ->
          held_writer :=
            Some
              (Eta_http_h2.Connection.Server.Reqd.respond_with_streaming reqd
                 (h2_server_response 200)))
    in
    let mux = h2_mux_create (h2_mux_result ()) () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let body_ref = ref None in
    let writer = h2_open_streaming_body mux client server held_writer body_ref in
    ignore (Eta_http_h2.Body.Writer.write_string writer "prefix");
    B.with_test_clock @@ fun _ctx _clock rt ->
    let body = h2_response_body "discard" !body_ref in
    let chunk = Eta_http.Body.Stream.read body |> B.run rt |> expect_ok in
    Alcotest.(check (option string)) "first chunk" (Some "prefix")
      (Option.map Bytes.to_string chunk);
    Eta_http.Body.Stream.discard body |> B.run rt |> expect_ok;
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active" 0 stats.active;
    Alcotest.(check int) "live" 0 stats.live;
    Alcotest.(check int) "local reset" 1 stats.local_resets

  let test_h2_multiplexer_sustains_100_concurrent_gets () =
    let connection_result = h2_mux_result () in
    let server =
      h2_create_server (fun reqd ->
          let target = (Eta_http_h2.Connection.Server.Reqd.request reqd).path in
          Eta_http_h2.Connection.Server.Reqd.respond_with_string reqd
            (h2_server_response ~body:(`String ("get:" ^ target)) 200)
            ("get:" ^ target))
    in
    let mux = h2_mux_create connection_result () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let results = List.init 100 (fun _ -> h2_mux_result ()) in
    List.iteri
      (fun i result ->
        ignore
          (h2_opened "concurrent GET"
             (h2_open_mux_request ~tag:i
                ~target:(Printf.sprintf "/concurrent/%d" i)
                mux result)))
      results;
    h2_pump_pair client server;
    List.iteri
      (fun i result ->
        Alcotest.(check (option int)) "status" (Some 200) result.mux_status;
        Alcotest.(check string) "body"
          (Printf.sprintf "get:/concurrent/%d" i)
          (Buffer.contents result.mux_body);
        Alcotest.(check bool) "eof" true result.mux_eof;
        Alcotest.(check int) "stream errors" 0
          (List.length result.mux_stream_errors);
        Alcotest.(check bool) "release complete" true
          (Eta_http_eio.H2.Multiplexer.release mux
             (h2_stream_of_result "concurrent GET" result)
          = Eta_http_h2.Stream_state.No_rst))
      results;
    Alcotest.(check int) "connection errors" 0
      (List.length connection_result.mux_client_errors);
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active" 0 stats.active;
    Alcotest.(check int) "cancelled" 0 stats.cancelled;
    Alcotest.(check int) "live" 0 stats.live;
    Alcotest.(check int) "opened" 100 stats.opened;
    Alcotest.(check int) "completed" 100 stats.completed;
    Alcotest.(check int) "max inflight" 100 stats.max_inflight

  let test_h2_multiplexer_upload_flow_control_resumes () =
    let connection_result = h2_mux_result () in
    let held = ref None in
    let server =
      h2_create_server (fun reqd ->
          match (Eta_http_h2.Connection.Server.Reqd.request reqd).meth, (Eta_http_h2.Connection.Server.Reqd.request reqd).path with
          | "POST", "/upload-hold" -> held := Some reqd
          | _ ->
              Eta_http_h2.Connection.Server.Reqd.respond_with_string reqd
                (h2_server_response ~body:(`String "unexpected") 200)
                "unexpected")
    in
    let mux = h2_mux_create connection_result () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let result = h2_mux_result () in
    let payload = String.make (128 * 1024) 'x' in
    ignore
      (h2_opened "upload"
         (h2_open_mux_request ~meth:`POST ~body:payload ~target:"/upload-hold"
            mux result));
    h2_pump_pair client server;
    Alcotest.(check (option int)) "no response before server body read" None
      result.mux_status;
    let reqd =
      match !held with
      | Some reqd -> reqd
      | None -> Alcotest.fail "server did not hold upload request"
    in
    h2_server_read_body reqd ~on_done:(fun body ->
        let response = Printf.sprintf "upload:%d" (String.length body) in
        Eta_http_h2.Connection.Server.Reqd.respond_with_string reqd
          (h2_server_response ~body:(`String response) 200)
          response);
    h2_pump_pair client server;
    Alcotest.(check (option int)) "status" (Some 200) result.mux_status;
    Alcotest.(check string) "body" "upload:131072"
      (Buffer.contents result.mux_body);
    Alcotest.(check bool) "eof" true result.mux_eof;
    Alcotest.(check bool) "release complete" true
      (Eta_http_eio.H2.Multiplexer.release mux (h2_stream_of_result "upload" result)
      = Eta_http_h2.Stream_state.No_rst);
    Alcotest.(check int) "connection errors" 0
      (List.length connection_result.mux_client_errors)

  let test_h2_multiplexer_server_reset_admission_release () =
    let connection_result = h2_mux_result () in
    let server =
      h2_create_server (fun reqd ->
          let body =
            Eta_http_h2.Connection.Server.Reqd.respond_with_streaming reqd
              (h2_server_response 200)
          in
          ignore (Eta_http_h2.Body.Writer.write_string body "partial");
          Eta_http_h2.Connection.Server.Reqd.report_exn reqd (Failure "reset-fixture"))
    in
    let mux = h2_mux_create ~max_concurrent:32 connection_result () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let results = List.init 32 (fun _ -> h2_mux_result ()) in
    List.iteri
      (fun i result ->
        ignore
          (h2_opened "reset"
             (h2_open_mux_request ~tag:i ~target:"/rst" mux result)))
      results;
    h2_pump_pair client server;
    List.iter
      (fun result ->
        Alcotest.(check bool) "stream error observed" true
          (List.length result.mux_stream_errors > 0))
      results;
    let stats_after_reset = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active after reset" 0 stats_after_reset.active;
    Alcotest.(check int) "cancelled after reset" 32 stats_after_reset.cancelled;
    Alcotest.(check int) "live after reset" 32 stats_after_reset.live;
    Alcotest.(check int) "remote resets" 32 stats_after_reset.remote_resets;
    let rejected =
      List.init 100 (fun i ->
          let result = h2_mux_result () in
          match h2_open_mux_request ~tag:(1000 + i) ~target:"/rst" mux result with
          | Error `Admission_rejected -> 1
          | Error `Connection_closed -> Alcotest.fail "connection closed"
          | Error (`Request_failed message) ->
              Alcotest.failf "request failed: %s" message
          | Ok _ -> Alcotest.fail "cancelled streams should still occupy admission")
      |> List.fold_left ( + ) 0
    in
    Alcotest.(check int) "rejected while cancelled admitted" 100 rejected;
    List.iter
      (fun result ->
        Alcotest.(check bool) "remote reset release" true
          (Eta_http_eio.H2.Multiplexer.release mux
             (h2_stream_of_result "reset" result)
          = Eta_http_h2.Stream_state.No_rst))
      results;
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active final" 0 stats.active;
    Alcotest.(check int) "cancelled final" 0 stats.cancelled;
    Alcotest.(check int) "live final" 0 stats.live;
    Alcotest.(check int) "completed" 32 stats.completed;
    Alcotest.(check int) "admission rejected" 100 stats.admission_rejected;
    Alcotest.(check int) "max inflight" 32 stats.max_inflight;
    Alcotest.(check int) "connection errors" 0
      (List.length connection_result.mux_client_errors)

  let test_h2_multiplexer_client_cancel_releases_stream () =
    let connection_result = h2_mux_result () in
    let server =
      h2_create_server (fun reqd ->
          match (Eta_http_h2.Connection.Server.Reqd.request reqd).path with
          | "/slow" ->
              let body =
                Eta_http_h2.Connection.Server.Reqd.respond_with_streaming reqd
                  (h2_server_response 200)
              in
              ignore (Eta_http_h2.Body.Writer.write_string body "slow-prefix")
          | target ->
              Eta_http_h2.Connection.Server.Reqd.respond_with_string reqd
                (h2_server_response ~body:(`String ("get:" ^ target)) 200)
                ("get:" ^ target))
    in
    let mux = h2_mux_create connection_result () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let first = h2_mux_result () in
    let request = h2_core_request ~target:"/slow" () in
    let opened =
      match
        Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
          ~error_handler:(fun stream error ->
            first.mux_stream <- Some stream;
            first.mux_stream_errors <-
              h2_pp_client_error error :: first.mux_stream_errors)
          ~response_handler:(fun stream response response_body ->
            first.mux_stream <- Some stream;
            first.mux_status <- Some response.status;
            Eta_http_h2.Body.Reader.schedule_read response_body
              ~on_eof:(fun () -> Alcotest.fail "slow response ended early")
              ~on_read:(fun bs ~off ~len ->
                Buffer.add_string first.mux_body
                  (Bigstringaf.substring bs ~off ~len);
                first.mux_release <-
                  Some (Eta_http_eio.H2.Multiplexer.release mux stream)))
      with
      | Ok opened -> opened
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
          Alcotest.fail "slow request rejected"
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "slow request saw closed connection"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "slow request failed: %s" message
    in
    Eta_http_h2.Body.Writer.close opened.request_body;
    h2_pump_pair client server;
    Alcotest.(check (option int)) "slow status" (Some 200) first.mux_status;
    Alcotest.(check string) "first chunk" "slow-prefix"
      (Buffer.contents first.mux_body);
    Alcotest.(check bool) "released active stream" true
      (first.mux_release = Some Eta_http_h2.Stream_state.Queue_rst);
    let after = h2_mux_result () in
    ignore
      (h2_opened "after cancel"
         (h2_open_mux_request ~tag:2 ~target:"/after-cancel" mux after));
    h2_pump_pair client server;
    Alcotest.(check (option int)) "after status" (Some 200) after.mux_status;
    Alcotest.(check string) "after body" "get:/after-cancel"
      (Buffer.contents after.mux_body);
    Alcotest.(check bool) "after release" true
      (Eta_http_eio.H2.Multiplexer.release mux
         (h2_stream_of_result "after cancel" after)
      = Eta_http_h2.Stream_state.No_rst);
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "active final" 0 stats.active;
    Alcotest.(check int) "live final" 0 stats.live;
    Alcotest.(check int) "local resets" 1 stats.local_resets;
    Alcotest.(check int) "connection errors" 0
      (List.length connection_result.mux_client_errors)

  let test_h2_multiplexer_release_closes_open_request_body () =
    let result = h2_mux_result () in
    let mux = h2_mux_create result () in
    let request =
      h2_core_request ~meth:"POST" ~target:"/release-open-request-body" ()
    in
    let opened =
      match
        Eta_http_eio.H2.Multiplexer.request mux ~tag:7 request
          ~error_handler:(fun stream error ->
            result.mux_stream <- Some stream;
            result.mux_stream_errors <-
              h2_pp_client_error error :: result.mux_stream_errors)
          ~response_handler:(fun stream response _body ->
            result.mux_stream <- Some stream;
            result.mux_status <- Some response.status)
      with
      | Ok opened -> opened
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
          Alcotest.fail "request rejected"
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "connection closed"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "request failed: %s" message
    in
    Alcotest.(check bool) "request body starts open" false
      (Eta_http_h2.Body.Writer.is_closed opened.request_body);
    ignore (Eta_http_eio.H2.Multiplexer.release mux opened.stream);
    Alcotest.(check bool) "release closes request body" true
      (Eta_http_h2.Body.Writer.is_closed opened.request_body)

  let rec h2_drain_client_writes client =
    match Eta_http_h2.Connection.next_write_operation client with
    | Write iovecs ->
        let data = h2_iovecs_to_string iovecs in
        Eta_http_h2.Connection.report_write_result client
          (`Ok (String.length data));
        1 + h2_drain_client_writes client
    | Yield -> 0
    | Close _ ->
        Eta_http_h2.Connection.report_write_result client `Closed;
        0

  let test_h2_multiplexer_rejects_after_goaway () =
    let connection_result = h2_mux_result () in
    let mux = h2_mux_create connection_result () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let first = h2_mux_result () in
    ignore
      (h2_opened "before GOAWAY"
         (h2_open_mux_request ~tag:1 ~target:"/before-goaway" mux first));
    ignore (h2_drain_client_writes client);
    h2_feed_client client
      (Eta_http_h2.Frame.settings
      ^ Eta_http_h2.Frame.goaway_no_error ~last_stream_id:1);
    Alcotest.(check bool) "transport open before GOAWAY flush" false
      (Eta_http_h2.Connection.is_closed client);
    ignore (h2_drain_client_writes client);
    Alcotest.(check bool) "transport still draining after GOAWAY" false
      (Eta_http_h2.Connection.is_closed client);
    Alcotest.(check bool) "admission closed after GOAWAY" false
      (Eta_http_h2.Connection.accepts_new_streams client);
    let after = h2_mux_result () in
    (match h2_open_mux_request ~tag:2 ~target:"/after-goaway" mux after with
    | Error `Connection_closed -> ()
    | Error `Admission_rejected ->
        Alcotest.fail "GOAWAY reported as admission pressure"
    | Error (`Request_failed message) ->
        Alcotest.failf "GOAWAY request failed: %s" message
    | Ok _ -> Alcotest.fail "post-GOAWAY request was admitted");
    let stats = Eta_http_eio.H2.Multiplexer.stats mux in
    Alcotest.(check int) "opened before only" 1 stats.opened;
    Alcotest.(check int) "no admission pressure" 0 stats.admission_rejected

  let test_h2_body_stream_sync_delivers_prebuffered_body () =
    let num_chunks = 256 in
    let chunk_data = String.make 1024 'x' in
    let total_size = num_chunks * String.length chunk_data in
    let mux_config =
      {
        Eta_http_h2.Config.default with
        response_body_buffer_size = total_size;
        initial_window_size = total_size * 2;
      }
    in
    let server_settings =
      Eta_http_h2.Settings.create ~initial_window_size:(total_size * 2) ()
    in
    let held_writer = ref None in
    let server =
      h2_create_server ~config:server_settings (fun reqd ->
          held_writer :=
            Some
              (Eta_http_h2.Connection.Server.Reqd.respond_with_streaming reqd
                 (h2_server_response 200)))
    in
    let mux = h2_mux_create ~config:mux_config (h2_mux_result ()) () in
    let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
    let body_stream_ref = ref None in
    let request =
      h2_core_request ~target:"/large-buffered-sync" ()
    in
    let closed_error =
      Eta_http.Error.make ~protocol:Eta_http.Error.H2 ~method_:"GET"
        ~uri:"https://api.example.test/large-buffered-sync"
        (Eta_http.Error.Connection_closed
           { during = Eta_http.Error.Http_response })
    in
    let opened =
      match
        Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
          ~error_handler:(fun _ _ -> ())
          ~response_handler:(fun stream _ body ->
            let pump () =
              match h2_drain_server_to_client server client with
              | true -> Eta.Effect.pure (Eta_http_eio.H2.Multiplexer.Read 1)
              | false -> Eta.Effect.pure (Eta_http_eio.H2.Multiplexer.Read 0)
            in
            body_stream_ref :=
              Some
                (Eta_http_eio.H2.Multiplexer.body_stream ~closed_error ~pump mux stream
                   body))
      with
      | Ok opened -> opened
      | Error _ -> Alcotest.fail "request setup failed"
    in
    Eta_http_h2.Body.Writer.close opened.request_body;
    h2_pump_pair client server;
    let writer =
      match !held_writer with
      | Some writer -> writer
      | None -> Alcotest.fail "server did not install writer"
    in
    for _ = 1 to num_chunks do
      ignore (Eta_http_h2.Body.Writer.write_string writer chunk_data)
    done;
    Eta_http_h2.Body.Writer.close writer;
    h2_pump_pair client server;
    match !body_stream_ref with
    | None -> Alcotest.fail "body_stream was never created"
    | Some body_stream ->
        B.with_test_clock @@ fun _ctx _clock rt ->
        let body =
          B.run rt
            (Eta_http.Body.Stream.read_all ~max_bytes:total_size body_stream)
          |> expect_ok
        in
        Alcotest.(check int)
          "full body delivered without loss" total_size (Bytes.length body)

  let tests =
    [
      ( "h2-multiplexer",
        [
          Alcotest.test_case "body stream releases on EOF" `Quick
            test_h2_body_stream_releases_on_eof;
          Alcotest.test_case "body stream reads inline data" `Quick
            test_h2_body_stream_reads_inline_data_after_header_pump;
          Alcotest.test_case "response trailers" `Quick
            test_h2_multiplexer_delivers_response_trailers;
          Alcotest.test_case "body stream discard releases" `Quick
            test_h2_body_stream_discard_releases_active_stream;
          Alcotest.test_case "100 concurrent GETs" `Quick
            test_h2_multiplexer_sustains_100_concurrent_gets;
          Alcotest.test_case "upload flow-control resumes" `Quick
            test_h2_multiplexer_upload_flow_control_resumes;
          Alcotest.test_case "server reset admission release" `Quick
            test_h2_multiplexer_server_reset_admission_release;
          Alcotest.test_case "client cancel releases stream" `Quick
            test_h2_multiplexer_client_cancel_releases_stream;
          Alcotest.test_case "release closes open request body" `Quick
            test_h2_multiplexer_release_closes_open_request_body;
          Alcotest.test_case "GOAWAY rejects new streams" `Quick
            test_h2_multiplexer_rejects_after_goaway;
          Alcotest.test_case "body_stream sync prebuffered body" `Quick
            test_h2_body_stream_sync_delivers_prebuffered_body;
        ] );
    ]
end
