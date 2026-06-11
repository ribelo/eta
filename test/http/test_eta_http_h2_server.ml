open Test_eta_http_support

type failing_server_flow_mode =
  | Failing_read
  | Failing_write

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
    | Failing_write -> (
        match t.pending_read with
        | Some data ->
            t.pending_read <- None;
            read_string t _dst data
        | None -> raise End_of_file)

  let single_write t bufs =
    match t.mode with
    | Failing_read -> Cstruct.lenv bufs
    | Failing_write -> raise (Failure "server write boom")

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
  in
  let read_block, read_release =
    match mode with
    | Failing_read -> (None, None)
    | Failing_write -> (None, None)
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

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let pp_h2_client_error fmt = function
  | `Malformed_response message ->
      Format.fprintf fmt "malformed_response:%s" message
  | `Invalid_response_body_length _ ->
      Format.pp_print_string fmt "invalid_response_body_length"
  | `Protocol_error (code, message) ->
      Format.fprintf fmt "protocol_error:%a:%s" H2.Error_code.pp_hum code
        message
  | `Exn exn -> Format.fprintf fmt "exn:%s" (Printexc.to_string exn)

let await_h2_response ?(tag = 1) ?request_body ?trailers_ref connection request =
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
           request.authority ));
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
             ~headers:[ ("content-type", "text/plain") ]
             ~trailers:(fun () ->
               Eta.Effect.pure [ ("grpc-status", "0"); ("x-done", "yes") ])
             ~body ())
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
      let method_, path, query, scheme, authority =
        Eio.Promise.await seen_request
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "ok:/healthz\n" body;
      Alcotest.(check string) "method" "GET" method_;
      Alcotest.(check string) "path" "/healthz" path;
      Alcotest.(check (option string)) "query" (Some "token=secret") query;
      Alcotest.(check string) "scheme" "http" scheme;
      Alcotest.(check (option string)) "authority" (Some "127.0.0.1") authority;
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
      let trailers = ref None in
      let stream_request =
        H2.Request.create ~scheme:"http"
          ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1" ])
          `GET "/stream"
      in
      let stream_status, stream_body =
        await_h2_response ~tag:4 ~trailers_ref:trailers connection stream_request
      in
      Alcotest.(check int) "stream status" 200 stream_status;
      Alcotest.(check string) "stream body" "one-two" stream_body;
      Alcotest.(check (option string)) "grpc-status" (Some "0")
        (Option.bind !trailers (List.assoc_opt "grpc-status"));
      Alcotest.(check (option string)) "x-done" (Some "yes")
        (Option.bind !trailers (List.assoc_opt "x-done"));
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ());
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "active streams" 0 stats.active_streams;
      Alcotest.(check int) "opened streams" 4 stats.opened_streams;
      Alcotest.(check int) "completed streams" 4 stats.completed_streams;
      Alcotest.(check int) "reset streams" 0 stats.reset_streams;
      Alcotest.(check int) "request bytes" 10 stats.request_bytes;
      Alcotest.(check int) "protocol errors" 0 stats.protocol_errors;
      Alcotest.(check bool) "response bytes recorded" true
        (stats.response_bytes > 0))

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
