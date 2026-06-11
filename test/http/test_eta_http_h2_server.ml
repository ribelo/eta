open Test_eta_http_support

type failing_server_flow_mode =
  | Failing_read
  | Failing_write
  | Timeout_write of {
      request_bytes : string;
      timeout_writes : bool ref;
    }
  | Blocking_read of { request_bytes : string }

type failing_server_flow = {
  mode : failing_server_flow_mode;
  mutable shutdowns : int;
  mutable closes : int;
  mutable pending_read : string option;
  read_release : unit Eio.Promise.u option;
  read_block : unit Eio.Promise.t option;
}

module Failing_server_flow = struct
  type t = failing_server_flow

  let read_methods = []

  let read_string t dst data =
    let len = min (String.length data) (Cstruct.length dst) in
    Cstruct.blit_from_string data 0 dst 0 len;
    if len < String.length data then
      t.pending_read <- Some (String.sub data len (String.length data - len));
    len

  let single_read t _dst =
    match t.mode with
    | Failing_read -> raise (Failure "server read boom")
    | Failing_write | Timeout_write _ | Blocking_read _ -> (
        match t.pending_read with
        | Some data ->
            t.pending_read <- None;
            read_string t _dst data
        | None -> (
            match t.read_block with
            | None -> raise End_of_file
            | Some blocked ->
                Eio.Promise.await blocked;
                raise End_of_file))

  let single_write t bufs =
    match t.mode with
    | Failing_read -> Cstruct.lenv bufs
    | Failing_write -> raise (Failure "server write boom")
    | Timeout_write { timeout_writes; _ } ->
        if !timeout_writes then raise Eio.Time.Timeout else Cstruct.lenv bufs
    | Blocking_read _ -> Cstruct.lenv bufs

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src

  let shutdown t _ =
    t.shutdowns <- t.shutdowns + 1;
    Option.iter (fun release -> ignore (Eio.Promise.try_resolve release ()))
      t.read_release

  let close t =
    t.closes <- t.closes + 1;
    Option.iter (fun release -> ignore (Eio.Promise.try_resolve release ()))
      t.read_release
end

let failing_server_flow mode =
  let pending_read =
    match mode with
    | Failing_read -> None
    | Failing_write ->
        let client = H2.Client_connection.create ~error_handler:(fun _ -> ()) () in
        Some
          (match H2.Client_connection.next_write_operation client with
          | `Write iovecs -> Test_eta_http_h2_support.h2_iovecs_to_string iovecs
          | `Yield -> Alcotest.fail "client preface unexpectedly yielded"
          | `Close _ -> Alcotest.fail "client preface unexpectedly closed")
    | Timeout_write { request_bytes; _ } -> Some request_bytes
    | Blocking_read { request_bytes } ->
        if String.equal request_bytes "" then None else Some request_bytes
  in
  let read_block, read_release =
    match mode with
    | Failing_read | Failing_write | Timeout_write _ -> (None, None)
    | Blocking_read _ ->
        let blocked, release = Eio.Promise.create () in
        (Some blocked, Some release)
  in
  let state =
    { mode; shutdowns = 0; closes = 0; pending_read; read_block; read_release }
  in
  let flow : Eta_http_eio.H2.Server_connection.flow =
    Eio.Resource.T
      ( state,
        Eio.Resource.handler
          (Eio.Resource.H (Eio.Resource.Close, Failing_server_flow.close)
          :: Eio.Resource.bindings
               (Eio.Flow.Pi.two_way (module Failing_server_flow))) )
  in
  (state, flow)

let h2_client_request_bytes target =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"http"
      ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
      `GET target
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2.Body.Writer.close request_body;
  let rec drain acc =
    match H2.Client_connection.next_write_operation client with
    | `Write iovecs ->
        let data = Test_eta_http_h2_support.h2_iovecs_to_string iovecs in
        H2.Client_connection.report_write_result client
          (`Ok (String.length data));
        drain (data :: acc)
    | `Yield -> String.concat "" (List.rev acc)
    | `Close _ ->
        H2.Client_connection.report_write_result client `Closed;
        String.concat "" (List.rev acc)
  in
  drain []

let hpack_header name value = { Hpack.name; value; sensitive = false }

let hpack_block encoder headers =
  let faraday = Faraday.create 0x1000 in
  List.iter (Hpack.Encoder.encode_header encoder faraday) headers;
  Faraday.serialize_to_string faraday

let raw_h2_headers encoder ?(end_stream = false) ~stream_id headers =
  let block = hpack_block encoder headers in
  let flags = 0x4 lor (if end_stream then 0x1 else 0) in
  Eta_http.H2.Frame.header ~length:(String.length block) ~frame_type:Headers
    ~flags ~stream_id
  ^ block

let raw_h2_data ?(end_stream = false) ~stream_id data =
  let flags = if end_stream then 0x1 else 0 in
  Eta_http.H2.Frame.header ~length:(String.length data) ~frame_type:Data ~flags
    ~stream_id
  ^ data

let h2_client_partial_request_bytes target body =
  let encoder = Hpack.Encoder.create 4096 in
  "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  ^ Eta_http.H2.Frame.settings
  ^ raw_h2_headers encoder ~stream_id:1
      [
        hpack_header ":method" "POST";
        hpack_header ":scheme" "http";
        hpack_header ":path" target;
        hpack_header ":authority" "127.0.0.1";
      ]
  ^ raw_h2_data ~stream_id:1 body

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let read_raw_until_close flow =
  let buffer = Buffer.create 128 in
  let scratch = Cstruct.create 1024 in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> Buffer.contents buffer
    | len ->
        Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 len));
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let pp_h2_client_error fmt = function
  | `Malformed_response message ->
      Format.fprintf fmt "malformed_response:%s" message
  | `Invalid_response_body_length _ ->
      Format.pp_print_string fmt "invalid_response_body_length"
  | `Protocol_error (code, message) ->
      Format.fprintf fmt "protocol_error:%a:%s" H2.Error_code.pp_hum code
        message
  | `Exn exn -> Format.fprintf fmt "exn:%s" (Printexc.to_string exn)

let await_h2_response ?(tag = 1) ?request_body ?headers_ref ?trailers_ref
    connection request =
  let status = ref None in
  let body = Buffer.create 32 in
  let eof, resolve_eof = Eio.Promise.create () in
  let rec read_body response_body =
    H2.Body.Reader.schedule_read response_body
      ~on_eof:(fun () -> ignore (Eio.Promise.try_resolve resolve_eof ()))
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string body (Bigstringaf.substring bs ~off ~len);
        read_body response_body)
  in
  let trailers_handler =
    Option.map
      (fun trailers_ref trailers ->
        trailers_ref := Some (H2.Headers.to_list trailers))
      trailers_ref
  in
  match
    Eta_http_eio.H2.Connection.request connection ~tag ?trailers_handler request
      ~error_handler:(fun _stream error ->
        Alcotest.failf "unexpected h2 stream error: %a"
          pp_h2_client_error error)
      ~response_handler:(fun _stream response response_body ->
        status := Some (H2.Status.to_code response.status);
        Option.iter
          (fun headers_ref -> headers_ref := Some (H2.Headers.to_list response.headers))
          headers_ref;
        read_body response_body)
  with
  | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected { limit }) ->
      Alcotest.failf "request rejected by admission limit=%d" limit
  | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
      Alcotest.fail "connection closed before request"
  | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
      Alcotest.failf "request failed: %s" message
  | Ok opened ->
      (match request_body with
      | None -> ()
      | Some body -> H2.Body.Writer.write_string opened.request_body body);
      H2.Body.Writer.close opened.request_body;
      Eio.Promise.await eof;
      (Option.value ~default:0 !status, Buffer.contents body)

let await_h2_response_outcome ?(tag = 1) connection request =
  let status = ref None in
  let body = Buffer.create 32 in
  let done_, resolve_done = Eio.Promise.create () in
  let resolve_done_once outcome =
    ignore (Eio.Promise.try_resolve resolve_done outcome)
  in
  let rec read_body response_body =
    H2.Body.Reader.schedule_read response_body
      ~on_eof:(fun () ->
        resolve_done_once
          (`Eof (Option.value ~default:0 !status, Buffer.contents body)))
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string body (Bigstringaf.substring bs ~off ~len);
        read_body response_body)
  in
  match
    Eta_http_eio.H2.Connection.request connection ~tag request
      ~error_handler:(fun _stream error ->
        resolve_done_once
          (`Error
             ( Option.value ~default:0 !status,
               Buffer.contents body,
               error )))
      ~response_handler:(fun _stream response response_body ->
        status := Some (H2.Status.to_code response.status);
        read_body response_body)
  with
  | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected { limit }) ->
      Alcotest.failf "request rejected by admission limit=%d" limit
  | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
      Alcotest.fail "connection closed before request"
  | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
      Alcotest.failf "request failed: %s" message
  | Ok opened ->
      H2.Body.Writer.close opened.request_body;
      Eio.Promise.await done_

let run_h2c_with_failing_flow mode =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state, flow = failing_server_flow mode in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler _request =
    Alcotest.fail "failing flow should not reach the handler"
  in
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config:Eta_http_eio.Server.Config.default ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let stats = Eio.Promise.await closed_stats in
  Alcotest.(check int) "active streams" 0 stats.active_streams;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2c_server_read_exception_closes_typed () =
  run_h2c_with_failing_flow Failing_read

let test_h2c_server_write_exception_closes_typed () =
  run_h2c_with_failing_flow Failing_write

let test_h2c_server_response_write_timeout_is_typed () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let timeout_writes = ref false in
  let state, flow =
    failing_server_flow
      (Timeout_write
         {
           request_bytes = h2_client_request_bytes "/response-timeout";
           timeout_writes;
         })
  in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let release_seen, resolve_release_seen = Eio.Promise.create () in
  let released = ref 0 in
  let server_timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      response_write_timeout = Some (Eta.Duration.ms 1);
    }
  in
  let server_config =
    { Eta_http.Server.Config.default with timeouts = server_timeouts }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler (request : Eta_http.Server.Request.t) =
    Alcotest.(check string) "path" "/response-timeout" request.path;
    let sent = ref false in
    let body =
      Eta_http.Server.Response.Body.stream
        ~release:(fun () ->
          Eta.Effect.sync (fun () ->
              incr released;
              ignore (Eio.Promise.try_resolve resolve_release_seen ())))
        (fun () ->
          if !sent then Eta.Effect.pure None
          else (
            sent := true;
            timeout_writes := true;
            Eta.Effect.pure (Some (Bytes.of_string "blocked"))))
    in
    Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
  in
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      Eio.Promise.await release_seen);
  let stats = Eio.Promise.await closed_stats in
  Alcotest.(check bool) "timeout armed" true !timeout_writes;
  Alcotest.(check int) "released stream" 1 !released;
  Alcotest.(check int) "active streams" 0 stats.active_streams;
  Alcotest.(check int) "completed streams" 0 stats.completed_streams;
  Alcotest.(check int) "reset streams" 1 stats.reset_streams;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2c_server_handler_timeout () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      handler_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler_calls = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.sync (fun () ->
        Eio.Time.sleep clock 1.0;
        Eta_http.Server.Response.text "late\n")
  in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~config ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/slow-handler"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response connection request)
      in
      Alcotest.(check int) "status" 503 status;
      Alcotest.(check string) "body" "service unavailable\n" body;
      Alcotest.(check int) "handler calls" 1 !handler_calls)

let test_h2c_server_response_body_timeout_resets_stream () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      response_body_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let released, resolve_released = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/slow-response-body" ->
        let body =
          Eta_http.Server.Response.Body.stream
            ~release:(fun () ->
              Eta.Effect.sync (fun () ->
                  ignore (Eio.Promise.try_resolve resolve_released ())))
            (fun () ->
              Eta.Effect.sync (fun () ->
                  Eio.Time.sleep clock 1.0;
                  Some (Bytes.of_string "late")))
        in
        Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~config ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let slow =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/slow-response-body"
      in
      let outcome =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response_outcome connection slow)
      in
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
          Eio.Promise.await released);
      (match outcome with
      | `Error (status, body, _error) ->
          Alcotest.(check int) "partial status" 200 status;
          Alcotest.(check string) "partial body" "" body
      | `Eof (status, body) ->
          Alcotest.failf
            "expected stream reset after response body timeout, got EOF \
             status=%d body=%S"
            status body);
      let ok =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/ok"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response ~tag:2 connection ok)
      in
      Alcotest.(check int) "connection reusable status" 200 status;
      Alcotest.(check string) "connection reusable body" "ok\n" body)

let test_h2c_server_enforces_max_concurrent_streams () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let config =
    {
      Eta_http_eio.Server.Config.default with
      h2_config =
        {
          Eta_http_eio.Server.Config.default.h2_config with
          max_concurrent_streams = 1l;
        };
    }
  in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/hold" ->
        let body =
          Eta_http.Server.Response.Body.stream (fun () ->
              Eta.Effect.sync (fun () ->
                  Eio.Promise.await release_first;
                  None))
        in
        Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~config ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eio.Promise.try_resolve resolve_release_first ());
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let first_response, resolve_first_response = Eio.Promise.create () in
      let first_eof, resolve_first_eof = Eio.Promise.create () in
      let first_body = ref None in
      let first =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/hold"
      in
      (match
         Eta_http_eio.H2.Connection.request connection ~tag:1 first
           ~error_handler:(fun _stream error ->
             Alcotest.failf "first stream failed: %a" pp_h2_client_error error)
           ~response_handler:(fun _stream response response_body ->
             first_body := Some response_body;
             ignore
               (Eio.Promise.try_resolve resolve_first_response
                  (H2.Status.to_code response.status)))
       with
      | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected { limit }) ->
          Alcotest.failf "first request rejected by admission limit=%d" limit
      | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
          Alcotest.fail "connection closed before first request"
      | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
          Alcotest.failf "first request failed: %s" message
      | Ok opened -> H2.Body.Writer.close opened.request_body);
      let first_status =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await first_response)
      in
      Alcotest.(check int) "first status" 200 first_status;
      let second =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/second"
      in
      let second_outcome =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response_outcome ~tag:2 connection second)
      in
      (match second_outcome with
      | `Error (_status, _body, _error) -> ()
      | `Eof (status, body) ->
          Alcotest.failf
            "expected max concurrent stream reset, got EOF status=%d body=%S"
            status body);
      ignore (Eio.Promise.try_resolve resolve_release_first ());
      let rec read_first_body response_body =
        H2.Body.Reader.schedule_read response_body
          ~on_eof:(fun () ->
            ignore (Eio.Promise.try_resolve resolve_first_eof ()))
          ~on_read:(fun _bs ~off:_ ~len:_ -> read_first_body response_body)
      in
      (match !first_body with
      | None -> Alcotest.fail "first response body missing"
      | Some response_body -> read_first_body response_body);
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
          Eio.Promise.await first_eof))

let test_h2c_server_fixed_response_and_echo_body () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let stop, resolve_stop = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close stats =
    ignore (Eio.Promise.try_resolve resolve_closed_stats stats)
  in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         ( request.method_,
           request.path,
           request.query,
           request.scheme,
           request.authority,
           request.tls,
           request.alpn_protocol,
           request.connection_id ));
    match request.path with
    | "/echo" ->
        Eta_http.Server.Body.read_all request.body
        |> Eta.Effect.map (fun body ->
               Eta_http.Server.Response.make ~status:200
                 ~body:(Eta_http.Server.Response.Body.fixed [ body ])
                 ())
    | "/early" ->
        Eta.Effect.pure
          (Eta_http.Server.Response.text ("early:" ^ request.path ^ "\n"))
    | "/stream" ->
        let chunks =
          ref
            [
              Bytes.of_string "one";
              Bytes.of_string "-";
              Bytes.of_string "two";
            ]
        in
        let body =
          Eta_http.Server.Response.Body.stream (fun () ->
              match !chunks with
              | [] -> Eta.Effect.pure None
              | chunk :: rest ->
                  chunks := rest;
                  Eta.Effect.pure (Some chunk))
        in
        Eta.Effect.pure
          (Eta_http.Server.Response.make ~status:200
             ~headers:[ ("Content-Type", "text/plain") ]
             ~trailers:(fun () ->
               Eta.Effect.pure [ ("Grpc-Status", "0"); ("X-Done", "yes") ])
             ~body ())
    | "/large-fixed" ->
        Eta.Effect.pure
          (Eta_http.Server.Response.make ~status:200
             ~body:
               (Eta_http.Server.Response.Body.fixed
                  [ Bytes.make (64 * 1024) 'z' ])
             ())
    | _ ->
        Eta.Effect.pure
          (Eta_http.Server.Response.text ("ok:" ^ request.path ^ "\n"))
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop
        ~on_connection_close ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/healthz?token=secret"
      in
      let status, body = await_h2_response connection request in
      let method_, path, query, scheme, authority, tls, alpn_protocol,
          connection_id =
        Eio.Promise.await seen_request
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "ok:/healthz\n" body;
      Alcotest.(check string) "method" "GET" method_;
      Alcotest.(check string) "path" "/healthz" path;
      Alcotest.(check (option string)) "query" (Some "token=secret") query;
      Alcotest.(check string) "scheme" "http" scheme;
      Alcotest.(check (option string)) "authority" (Some "127.0.0.1") authority;
      Alcotest.(check bool) "tls" false tls;
      Alcotest.(check (option string)) "alpn protocol" (Some "h2c")
        alpn_protocol;
      Alcotest.(check bool) "connection id prefix" true
        (String.starts_with ~prefix:"h2c-" connection_id);
      let echo =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `POST "/echo"
      in
      let echo_status, echo_body =
        await_h2_response ~tag:2 ~request_body:"hello-post" connection echo
      in
      Alcotest.(check int) "echo status" 200 echo_status;
      Alcotest.(check string) "echo body" "hello-post" echo_body;
      let early =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `POST "/early"
      in
      let early_status, early_body =
        await_h2_response ~tag:3 ~request_body:"unread upload" connection early
      in
      Alcotest.(check int) "early status" 200 early_status;
      Alcotest.(check string) "early body" "early:/early\n" early_body;
      let stream_headers = ref None in
      let trailers = ref None in
      let stream_request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/stream"
      in
      let stream_status, stream_body =
        await_h2_response ~tag:4 ~headers_ref:stream_headers
          ~trailers_ref:trailers connection stream_request
      in
      Alcotest.(check int) "stream status" 200 stream_status;
      Alcotest.(check string) "stream body" "one-two" stream_body;
      Alcotest.(check (option string)) "content-type" (Some "text/plain")
        (Option.bind !stream_headers (List.assoc_opt "content-type"));
      Alcotest.(check (option string)) "grpc-status" (Some "0")
        (Option.bind !trailers (List.assoc_opt "grpc-status"));
      Alcotest.(check (option string)) "x-done" (Some "yes")
        (Option.bind !trailers (List.assoc_opt "x-done"));
      let large_fixed =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/large-fixed"
      in
      let large_status, large_body =
        await_h2_response ~tag:5 connection large_fixed
      in
      Alcotest.(check int) "large fixed status" 200 large_status;
      Alcotest.(check int) "large fixed length" (64 * 1024)
        (String.length large_body);
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ());
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "active streams" 0 stats.active_streams;
      Alcotest.(check int) "opened streams" 5 stats.opened_streams;
      Alcotest.(check int) "completed streams" 5 stats.completed_streams;
      Alcotest.(check int) "reset streams" 0 stats.reset_streams;
      Alcotest.(check int) "request bytes" 10 stats.request_bytes;
      Alcotest.(check int) "protocol errors" 0 stats.protocol_errors;
      Alcotest.(check bool) "response bytes recorded" true
        (stats.response_bytes > 0))

let test_h2c_server_rejects_invalid_request_metadata () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let handler_calls = ref 0 in
  let stop, resolve_stop = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path ^ "\n"))
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop
        ~on_connection_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let bad_path =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "noslash"
      in
      let missing_authority =
        H2.Request.create ~scheme:"http" ~headers:H2.Headers.empty `GET
          "/missing-authority"
      in
      let scheme_mismatch =
        H2.Request.create ~scheme:"https"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/scheme-mismatch"
      in
      List.iteri
        (fun index request ->
          let status, body =
            Eio.Time.with_timeout_exn clock 1.0 (fun () ->
                await_h2_response ~tag:(index + 1) connection request)
          in
          Alcotest.(check int) "invalid status" 400 status;
          Alcotest.(check string) "invalid body" "bad request\n" body)
        [ bad_path; missing_authority; scheme_mismatch ];
      let valid =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/valid"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response ~tag:4 connection valid)
      in
      Alcotest.(check int) "valid status" 200 status;
      Alcotest.(check string) "valid body" "ok:/valid\n" body;
      Alcotest.(check int) "handler calls" 1 !handler_calls;
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ());
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "protocol errors" 3 stats.protocol_errors)

let test_h2c_server_rejects_request_header_limit () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_limits =
    { Eta_http.Server.Config.default.limits with max_request_headers = 1 }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler_calls = ref 0 in
  let stop, resolve_stop = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let handler (_request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop
        ~on_connection_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        ~config ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/too-many-request-headers"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response connection request)
      in
      Alcotest.(check int) "status" 400 status;
      Alcotest.(check string) "body" "bad request\n" body;
      Alcotest.(check int) "handler calls" 0 !handler_calls;
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ());
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "protocol errors" 1 stats.protocol_errors)

let test_h2c_server_rejects_invalid_request_header () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let handler_calls = ref 0 in
  let stop, resolve_stop = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let handler (_request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop
        ~on_connection_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:
            (H2.Headers.of_list
               [ ":authority", "127.0.0.1"; "bad name", "value" ])
          `GET "/bad-header"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response connection request)
      in
      Alcotest.(check int) "status" 400 status;
      Alcotest.(check string) "body" "bad request\n" body;
      Alcotest.(check int) "handler calls" 0 !handler_calls;
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ());
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "protocol errors" 1 stats.protocol_errors)

let test_h2c_server_rejects_connection_specific_request_headers () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let handler_calls = ref 0 in
  let stop, resolve_stop = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path ^ "\n"))
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop
        ~on_connection_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let invalid =
        [
          [ ":authority", "127.0.0.1"; "connection", "close" ];
          [ ":authority", "127.0.0.1"; "te", "gzip" ];
          [ ":authority", "127.0.0.1"; "transfer-encoding", "chunked" ];
          [ ":authority", "127.0.0.1"; "upgrade", "websocket" ];
        ]
      in
      List.iteri
        (fun index headers ->
          let request =
            H2.Request.create ~scheme:"http"
              ~headers:(H2.Headers.of_list headers)
              `GET ("/invalid-h2-header-" ^ string_of_int index)
          in
          let outcome =
            Eio.Time.with_timeout_exn clock 1.0 (fun () ->
                await_h2_response_outcome ~tag:(index + 1) connection request)
          in
          match outcome with
          | `Eof (status, body) ->
              Alcotest.(check int) "invalid status" 400 status;
              Alcotest.(check string) "invalid body" "bad request\n" body
          | `Error (status, _body, _error) ->
              Alcotest.(check bool) "stream rejected" true
                (status = 0 || status = 400))
        invalid;
      let valid =
        H2.Request.create ~scheme:"http"
          ~headers:
            (H2.Headers.of_list
               [ ":authority", "127.0.0.1"; "te", "trailers" ])
          `GET "/valid-te"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response ~tag:5 connection valid)
      in
      Alcotest.(check int) "valid status" 200 status;
      Alcotest.(check string) "valid body" "ok:/valid-te\n" body;
      Alcotest.(check int) "handler calls" 1 !handler_calls;
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ());
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "protocol errors" 4 stats.protocol_errors)

let test_h2c_server_rejects_response_header_limit () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_limits =
    { Eta_http.Server.Config.default.limits with max_response_headers = 1 }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler_calls = ref 0 in
  let stop, resolve_stop = Eio.Promise.create () in
  let handler (_request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure
      (Eta_http.Server.Response.text
         ~headers:[ ("X-One", "1"); ("X-Two", "2") ]
         "too many headers\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop ~config ~socket
        handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/too-many-response-headers"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response connection request)
      in
      Alcotest.(check int) "status" 500 status;
      Alcotest.(check string) "body" "internal server error\n" body;
      Alcotest.(check int) "handler calls" 1 !handler_calls)

let test_h2c_server_rejects_connection_specific_response_header () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let stop, resolve_stop = Eio.Promise.create () in
  let handler_calls = ref 0 in
  let handler (_request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure
      (Eta_http.Server.Response.text
         ~headers:[ ("Connection", "close") ]
         "invalid h2 header\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/bad-response-header"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response connection request)
      in
      Alcotest.(check int) "status" 500 status;
      Alcotest.(check string) "body" "internal server error\n" body;
      Alcotest.(check int) "handler calls" 1 !handler_calls)

let test_h2c_server_rejects_connection_specific_response_trailer () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let stop, resolve_stop = Eio.Promise.create () in
  let handler (_request : Eta_http.Server.Request.t) =
    let sent = ref false in
    let body =
      Eta_http.Server.Response.Body.stream (fun () ->
          if !sent then Eta.Effect.pure None
          else (
            sent := true;
            Eta.Effect.pure (Some (Bytes.of_string "body"))))
    in
    Eta.Effect.pure
      (Eta_http.Server.Response.make ~status:200 ~body
         ~trailers:(fun () -> Eta.Effect.pure [ ("Connection", "close") ])
         ())
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/bad-response-trailer"
      in
      let outcome =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            await_h2_response_outcome connection request)
      in
      match outcome with
      | `Error (status, _body, _error) ->
          Alcotest.(check int) "status before reset" 200 status
      | `Eof (status, body) ->
          Alcotest.failf
            "expected stream reset after invalid trailer, got EOF status=%d \
             body=%S"
            status body)

let test_h2c_server_fragmented_large_upload_echo () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let config =
    { Eta_http_eio.Server.Config.default with read_buffer_size = 64 }
  in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun body ->
           Eta_http.Server.Response.make ~status:200
             ~body:(Eta_http.Server.Response.Body.fixed [ body ])
             ())
  in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~config ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let upload = String.make (32 * 1024) 'x' in
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:
            (H2.Headers.of_list
               [
                 ":authority", "127.0.0.1";
                 "content-length", string_of_int (String.length upload);
               ])
          `POST "/echo"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 2.0 (fun () ->
            await_h2_response ~request_body:upload connection request)
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check int) "body length" (String.length upload)
        (String.length body);
      Alcotest.(check string) "body" upload body)

let test_h2c_server_request_body_timeout () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server_timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      request_body_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config =
    { Eta_http.Server.Config.default with timeouts = server_timeouts }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let request_bytes = h2_client_partial_request_bytes "/timeout" "partial" in
  let state, flow = failing_server_flow (Blocking_read { request_bytes }) in
  let timeout_seen, resolve_timeout_seen = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/timeout" ->
        let expected = "partial" in
        let observed = Buffer.create (String.length expected) in
        let resolve_result result =
          ignore (Eio.Promise.try_resolve resolve_timeout_seen result)
        in
        let rec read_until_payload () =
          Eta_http.Server.Body.read request.body
          |> Eta.Effect.bind (function
               | Some chunk ->
                   Buffer.add_string observed (Bytes.to_string chunk);
                   if Buffer.length observed >= String.length expected then
                     Eta_http.Server.Body.read request.body
                   else read_until_payload ()
               | None ->
                   Eta.Effect.sync (fun () ->
                       resolve_result
                         (`Ended_before_timeout (Buffer.contents observed)))
                   |> Eta.Effect.map (fun () -> None))
        in
        read_until_payload ()
        |> Eta.Effect.map (fun next_chunk ->
               resolve_result
                 (`Unexpected_second_body
                   ( Option.map Bytes.to_string next_chunk,
                     Buffer.contents observed ));
               Eta_http.Server.Response.text ~status:500
                 "unexpected second body\n")
        |> Eta.Effect.catch (fun error ->
               Eta.Effect.sync (fun () ->
                   resolve_result
                     (`Timeout
                       ( Buffer.contents observed,
                         Eta_http.Server.Error.error_class error,
                         Eta_http.Server.Error.layer_to_string
                           (Eta_http.Server.Error.layer error) )))
               |> Eta.Effect.map (fun () ->
                      Eta_http.Server.Response.text ~status:408 "timeout\n"))
    | _ ->
        Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let timeout_result =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await timeout_seen)
  in
  (match timeout_result with
  | `Timeout (observed, error_class, error_layer) ->
      Alcotest.(check string) "observed body" "partial" observed;
      Alcotest.(check string) "error class" "request_timeout" error_class;
      Alcotest.(check string) "error layer" "request_body" error_layer
  | `Ended_before_timeout observed ->
      Alcotest.failf "request body ended before timeout after %S" observed
  | `Unexpected_second_body (next_chunk, observed) ->
      Alcotest.failf "expected timeout after %S, got second body chunk %S"
        observed
        (Option.value ~default:"<eof>" next_chunk));
  Eio.Flow.shutdown flow `All;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "active streams" 0 stats.active_streams;
  Alcotest.(check int) "request bytes" (String.length "partial")
    stats.request_bytes;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2c_server_request_body_too_large () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server_limits =
    {
      Eta_http.Server.Config.default.limits with
      max_request_body_bytes = Some 4;
    }
  in
  let server_config =
    { Eta_http.Server.Config.default with limits = server_limits }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let request_bytes =
    h2_client_partial_request_bytes "/too-large" "12345"
    ^ raw_h2_data ~end_stream:true ~stream_id:1 ""
  in
  let state, flow = failing_server_flow (Blocking_read { request_bytes }) in
  let body_error, resolve_body_error = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/too-large" ->
        Eta_http.Server.Body.read request.body
        |> Eta.Effect.map (fun _ ->
               Eta_http.Server.Response.text ~status:500 "unexpected body\n")
        |> Eta.Effect.catch (fun error ->
               Eta.Effect.sync (fun () ->
                   ignore
                     (Eio.Promise.try_resolve resolve_body_error
                        ( Eta_http.Server.Error.error_class error,
                          Eta_http.Server.Error.layer_to_string
                            (Eta_http.Server.Error.layer error) )))
               |> Eta.Effect.map (fun () ->
                      Eta_http.Server.Response.text ~status:413 "too large\n"))
    | path -> Alcotest.failf "unexpected path %S" path
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let error_class, error_layer =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await body_error)
  in
  Alcotest.(check string) "error class" "request_body_too_large" error_class;
  Alcotest.(check string) "error layer" "request_body" error_layer;
  Eio.Flow.shutdown flow `All;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "request bytes" 5 stats.request_bytes;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2c_server_unread_body_drain_timeout () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server_timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      request_body_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config =
    {
      Eta_http.Server.Config.default with
      timeouts = server_timeouts;
      unread_body_policy = Eta_http.Server.Config.Drain_up_to 64;
    }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let request_seen, resolve_request_seen = Eio.Promise.create () in
  let state, flow =
    failing_server_flow
      (Blocking_read
         {
           request_bytes =
             h2_client_partial_request_bytes "/ignored" "partial";
         })
  in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/ignored" ->
        Eta.Effect.sync (fun () ->
            ignore (Eio.Promise.try_resolve resolve_request_seen ()))
        |> Eta.Effect.map (fun () -> Eta_http.Server.Response.text "ignored\n")
    | path -> Alcotest.failf "unexpected path %S" path
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      Eio.Promise.await request_seen);
  Eio.Time.sleep clock 0.1;
  Eio.Flow.shutdown flow `All;
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "completed streams" 1 stats.completed_streams;
  Alcotest.(check int) "reset streams" 0 stats.reset_streams;
  Alcotest.(check int) "active streams" 0 stats.active_streams;
  Alcotest.(check int) "request bytes" (String.length "partial")
    stats.request_bytes;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2c_server_request_header_timeout () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server_timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      request_header_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config =
    { Eta_http.Server.Config.default with timeouts = server_timeouts }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let state, flow = failing_server_flow (Blocking_read { request_bytes = "" }) in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        (fun _request -> Alcotest.fail "request header timeout reached handler"));
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "opened streams" 0 stats.opened_streams;
  Alcotest.(check int) "active streams" 0 stats.active_streams;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2c_server_idle_timeout () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server_timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      idle_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config =
    { Eta_http.Server.Config.default with timeouts = server_timeouts }
  in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let request_seen, resolve_request_seen = Eio.Promise.create () in
  let state, flow =
    failing_server_flow
      (Blocking_read { request_bytes = h2_client_request_bytes "/idle" })
  in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/idle" ->
        Eta.Effect.sync (fun () ->
            ignore (Eio.Promise.try_resolve resolve_request_seen ()))
        |> Eta.Effect.map (fun () -> Eta_http.Server.Response.text "idle\n")
    | path -> Alcotest.failf "unexpected path %S" path
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~flow
        ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 31337))
        ~config ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      Eio.Promise.await request_seen);
  let stats =
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Promise.await closed_stats)
  in
  Alcotest.(check int) "opened streams" 1 stats.opened_streams;
  Alcotest.(check int) "active streams" 0 stats.active_streams;
  Alcotest.(check bool) "flow shutdown" true (state.shutdowns > 0)

let test_h2_server_connection_run_uses_connection_metadata () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let peer : Eta_http.Server.Request.peer =
    { address = Some "tls-peer.test"; port = Some 443 }
  in
  let connection_info : Eta_http_eio.Server.Connection_info.t =
    {
      id = "generic-h2-connection";
      peer;
      protocol = Eta_http.Server.Error.H2;
      tls = true;
      alpn_protocol = Some "h2";
    }
  in
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let runtime_factory ~sw ~connection:_ () =
    Eta_eio.Runtime.create ~sw ~clock ()
  in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         ( request.connection_id,
           request.tls,
           request.alpn_protocol,
           request.peer.address,
           request.peer.port,
           Eta_http.Core.Version.to_string request.version ));
    Eta.Effect.pure (Eta_http.Server.Response.text "generic-h2\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      Eta_http_eio.H2.Server_connection.run ~sw:conn_sw ~clock
        ~flow:(flow :> Eta_http_eio.H2.Server_connection.flow)
        ~connection:connection_info ~config:Eta_http_eio.Server.Config.default
        ~runtime_factory
        ~on_close:(fun stats ->
          ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
        handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let request =
        H2.Request.create ~scheme:"https"
          ~headers:(H2.Headers.of_list [ ":authority", "example.test" ])
          `GET "/metadata"
      in
      let status, body = await_h2_response connection request in
      let connection_id, tls, alpn_protocol, peer_address, peer_port, version =
        Eio.Promise.await seen_request
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "generic-h2\n" body;
      Alcotest.(check string) "connection id" "generic-h2-connection"
        connection_id;
      Alcotest.(check bool) "tls" true tls;
      Alcotest.(check (option string)) "alpn protocol" (Some "h2")
        alpn_protocol;
      Alcotest.(check (option string)) "peer address" (Some "tls-peer.test")
        peer_address;
      Alcotest.(check (option int)) "peer port" (Some 443) peer_port;
      Alcotest.(check string) "version" "h2" version;
      Eta_http_eio.H2.Connection.shutdown connection;
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "opened streams" 1 stats.opened_streams;
      Alcotest.(check int) "completed streams" 1 stats.completed_streams)

let test_h2c_server_drain_up_to_discard_waits_for_body () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let stop, resolve_stop = Eio.Promise.create () in
  let discard_started, resolve_discard_started = Eio.Promise.create () in
  let discard_returned, resolve_discard_returned = Eio.Promise.create () in
  let config =
    let open Eta_http_eio.Server.Config in
    {
      default with
      server =
        {
          default.server with
          unread_body_policy = Eta_http.Server.Config.Drain_up_to 4;
        };
    }
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/discard" ->
        ignore (Eio.Promise.try_resolve resolve_discard_started ());
        Eta_http.Server.Body.discard ~drain:true request.body
        |> Eta.Effect.map (fun () ->
               ignore (Eio.Promise.try_resolve resolve_discard_returned ());
               Eta_http.Server.Response.text "discarded\n")
    | _ ->
        Eta.Effect.pure (Eta_http.Server.Response.text "after\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop ~config ~socket
        handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let status = ref None in
      let body = Buffer.create 32 in
      let eof, resolve_eof = Eio.Promise.create () in
      let rec read_body response_body =
        H2.Body.Reader.schedule_read response_body
          ~on_eof:(fun () -> ignore (Eio.Promise.try_resolve resolve_eof ()))
          ~on_read:(fun bs ~off ~len ->
            Buffer.add_string body (Bigstringaf.substring bs ~off ~len);
            read_body response_body)
      in
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `POST "/discard"
      in
      let opened =
        match
          Eta_http_eio.H2.Connection.request connection ~tag:1 request
            ~error_handler:(fun _stream error ->
              Alcotest.failf "unexpected h2 stream error: %a"
                pp_h2_client_error error)
            ~response_handler:(fun _stream response response_body ->
              status := Some (H2.Status.to_code response.status);
              read_body response_body)
        with
        | Ok opened -> opened
        | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected { limit }) ->
            Alcotest.failf "request rejected by admission limit=%d" limit
        | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
            Alcotest.fail "connection closed before request"
        | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
            Alcotest.failf "request failed: %s" message
      in
      Eio.Promise.await discard_started;
      let returned_before_body =
        Eio.Fiber.first
          (fun () ->
            Eio.Promise.await discard_returned;
            true)
          (fun () ->
            Eio.Time.sleep clock 0.01;
            false)
      in
      Alcotest.(check bool) "discard waited for body" false returned_before_body;
      H2.Body.Writer.write_string opened.request_body "0123456789";
      H2.Body.Writer.close opened.request_body;
      Eio.Promise.await eof;
      Alcotest.(check bool) "discard returned" true
        (Eio.Promise.is_resolved discard_returned);
      Alcotest.(check (option int)) "discard status" (Some 200) !status;
      Alcotest.(check string) "discard body" "discarded\n"
        (Buffer.contents body);
      let after =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/after"
      in
      let after_status, after_body =
        await_h2_response ~tag:2 connection after
      in
      Alcotest.(check int) "after status" 200 after_status;
      Alcotest.(check string) "after body" "after\n" after_body;
      ignore (Eio.Promise.try_resolve resolve_stop ()))

let test_h2c_server_connection_close_fails_pending_body_read () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let stop, resolve_stop = Eio.Promise.create () in
  let read_started, resolve_read_started = Eio.Promise.create () in
  let body_error, resolve_body_error = Eio.Promise.create () in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/read" ->
        ignore (Eio.Promise.try_resolve resolve_read_started ());
        Eta_http.Server.Body.read request.body
        |> Eta.Effect.map (fun _ ->
               Eta_http.Server.Response.text "unexpected body\n")
        |> Eta.Effect.catch (fun error ->
               Eta.Effect.sync (fun () ->
                   ignore (Eio.Promise.try_resolve resolve_body_error error))
               |> Eta.Effect.map (fun () ->
                      Eta_http.Server.Response.text ~status:499
                        "connection closed\n"))
    | _ ->
        Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http_eio.Server.run_h2c_on_socket ~sw ~clock ~stop ~socket handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eio.Promise.try_resolve resolve_stop ());
      Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `POST "/read"
      in
      let opened =
        match
          Eta_http_eio.H2.Connection.request connection ~tag:1 request
            ~error_handler:(fun _stream _error -> ())
            ~response_handler:(fun _stream _response _response_body -> ())
        with
        | Ok opened -> opened
        | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected { limit }) ->
            Alcotest.failf "request rejected by admission limit=%d" limit
        | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
            Alcotest.fail "connection closed before request"
        | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
            Alcotest.failf "request failed: %s" message
      in
      ignore opened;
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
          Eio.Promise.await read_started);
      Eta_http_eio.H2.Connection.shutdown connection;
      let error =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await body_error)
      in
      Alcotest.(check string) "error class" "connection_closed"
        (Eta_http.Server.Error.error_class error);
      Alcotest.(check string) "error layer" "request_body"
        (Eta_http.Server.Error.layer_to_string
           (Eta_http.Server.Error.layer error)))

let test_h2c_server_handle_graceful_shutdown_waits_for_stream () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let handler_started, resolve_handler_started = Eio.Promise.create () in
  let release_handler, resolve_release_handler = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close stats =
    ignore (Eio.Promise.try_resolve resolve_closed_stats stats)
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/wait" ->
        Eta.Effect.sync (fun () ->
            ignore (Eio.Promise.try_resolve resolve_handler_started ());
            Eio.Promise.await release_handler;
            Eta_http.Server.Response.text "done\n")
    | _ ->
        Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~on_connection_close
      ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Eio.Promise.try_resolve resolve_release_handler ());
      Eta_http_eio.Server.shutdown server Immediate;
      Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let response, resolve_response = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          let request =
            H2.Request.create ~scheme:"http"
              ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
              `GET "/wait"
          in
          ignore
            (Eio.Promise.try_resolve resolve_response
               (await_h2_response connection request)));
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
          Eio.Promise.await handler_started);
      let stats = Eta_http_eio.Server.stats server in
      Alcotest.(check int) "active connections before shutdown" 1
        stats.active_connections;
      Alcotest.(check int) "opened connections before shutdown" 1
        stats.opened_connections;
      Alcotest.(check int) "closed connections before shutdown" 0
        stats.closed_connections;
      Eta_http_eio.Server.shutdown server (Graceful (Eta.Duration.ms 200));
      let closed_before_release =
        Eio.Fiber.first
          (fun () ->
            ignore (Eio.Promise.await closed_stats);
            true)
          (fun () ->
            Eio.Time.sleep clock 0.02;
            false)
      in
      Alcotest.(check bool) "graceful keeps active stream open" false
        closed_before_release;
      ignore (Eio.Promise.try_resolve resolve_release_handler ());
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await response)
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "done\n" body;
      let connection_stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "connection active streams" 0
        connection_stats.active_streams;
      Alcotest.(check int) "connection completed streams" 1
        connection_stats.completed_streams;
      Alcotest.(check int) "connection reset streams" 0
        connection_stats.reset_streams;
      let stats = Eta_http_eio.Server.stats server in
      Alcotest.(check int) "active connections after shutdown" 0
        stats.active_connections;
      Alcotest.(check int) "opened connections after shutdown" 1
        stats.opened_connections;
      Alcotest.(check int) "closed connections after shutdown" 1
        stats.closed_connections)

let test_h2c_server_closes_on_ingress_security_error () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let handler _request =
    Alcotest.fail "settings flood should close before request dispatch"
  in
  let server =
    Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock
      ~on_connection_close:(fun stats ->
        ignore (Eio.Promise.try_resolve resolve_closed_stats stats))
      ~socket handler
  in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.Server.shutdown server Immediate;
      try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () ->
      Eio.Flow.copy_string
        ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
       ^ String.concat ""
           (List.init 11 (fun _ -> Eta_http.H2.Frame.settings)))
        flow;
      ignore
        (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
             read_raw_until_close flow));
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "protocol errors" 1 stats.protocol_errors)
