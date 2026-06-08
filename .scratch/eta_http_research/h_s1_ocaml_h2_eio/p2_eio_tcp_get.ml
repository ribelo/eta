open H2

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let string_of_iovec { IOVec.buffer; off; len } =
  Bigstringaf.substring buffer ~off ~len

let pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
    Format.asprintf "protocol_error:%a:%s" Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let write_iovecs flow iovecs =
  let bufs =
    List.map
      (fun iovec -> Cstruct.of_string (string_of_iovec iovec))
      iovecs
  in
  Eio.Flow.write flow bufs

let read_into_connection flow read conn =
  let buf = Cstruct.create 0x4000 in
  let n = Eio.Flow.single_read flow buf in
  let data = Cstruct.to_string (Cstruct.sub buf 0 n) in
  let bs = Bigstringaf.of_string ~off:0 ~len:n data in
  ignore (read conn bs ~off:0 ~len:n : int)

let run_client_writer flow client =
  let rec loop () =
    match Client_connection.next_write_operation client with
    | `Write iovecs ->
      write_iovecs flow iovecs;
      let len =
        List.fold_left (fun total { IOVec.len; _ } -> total + len) 0 iovecs
      in
      Client_connection.report_write_result client (`Ok len);
      loop ()
    | `Yield ->
      let p, u = Eio.Promise.create () in
      Client_connection.yield_writer client (fun () ->
        ignore (Eio.Promise.try_resolve u ()));
      Eio.Promise.await p;
      loop ()
    | `Close _ ->
      (try Eio.Flow.shutdown flow `Send with _ -> ())
  in
  loop ()

let run_server_writer flow server =
  let rec loop () =
    match Server_connection.next_write_operation server with
    | `Write iovecs ->
      write_iovecs flow iovecs;
      let len =
        List.fold_left (fun total { IOVec.len; _ } -> total + len) 0 iovecs
      in
      Server_connection.report_write_result server (`Ok len);
      loop ()
    | `Yield ->
      let p, u = Eio.Promise.create () in
      Server_connection.yield_writer server (fun () ->
        ignore (Eio.Promise.try_resolve u ()));
      Eio.Promise.await p;
      loop ()
    | `Close _ ->
      (try Eio.Flow.shutdown flow `Send with _ -> ())
  in
  loop ()

let run_client_reader flow client =
  let rec loop () =
    match Client_connection.next_read_operation client with
    | `Read ->
      read_into_connection flow Client_connection.read client;
      loop ()
    | `Close -> ()
  in
  try loop () with End_of_file -> ()

let run_server_reader flow server =
  let rec loop () =
    match Server_connection.next_read_operation server with
    | `Read ->
      read_into_connection flow Server_connection.read server;
      loop ()
    | `Close -> ()
  in
  try loop () with End_of_file -> ()

let schedule_body_read body_buf done_u body =
  let rec loop () =
    if Body.Reader.is_closed body then ignore (Eio.Promise.try_resolve done_u ())
    else
      Body.Reader.schedule_read
        body
        ~on_eof:(fun () -> ignore (Eio.Promise.try_resolve done_u ()))
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string body_buf (Bigstringaf.substring bs ~off ~len);
          loop ())
  in
  loop ()

let run_server_connection flow =
  let server =
    Server_connection.create (fun reqd ->
      let request = Reqd.request reqd in
      let body =
        Printf.sprintf "eio-h2:%s" request.target
      in
      Reqd.respond_with_string
        reqd
        (Response.create
           ~headers:(Headers.of_list [ "content-type", "text/plain" ])
           `OK)
        body)
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    try run_server_writer flow server with _ -> ());
  (try run_server_reader flow server with _ -> ());
  Server_connection.shutdown server;
  try Eio.Flow.shutdown flow `All with _ -> ()

let run_client_connection flow =
  let body_buf = Buffer.create 32 in
  let done_p, done_u = Eio.Promise.create () in
  let client_errors = ref [] in
  let stream_errors = ref [] in
  let status = ref None in
  let client =
    Client_connection.create
      ~error_handler:(fun err ->
        client_errors := pp_client_error err :: !client_errors)
      ()
  in
  let request =
    Request.create
      ~scheme:"http"
      ~headers:(Headers.of_list [ ":authority", "local.test" ])
      `GET
      "/eio"
  in
  let request_body =
    Client_connection.request
      client
      request
      ~error_handler:(fun err ->
        stream_errors := pp_client_error err :: !stream_errors)
      ~response_handler:(fun response body ->
        status := Some (Status.to_code response.status);
        schedule_body_read body_buf done_u body)
  in
  Body.Writer.close request_body;
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    try run_client_writer flow client with _ -> ());
  Eio.Fiber.fork ~sw (fun () ->
    try run_client_reader flow client with _ -> ());
  Eio.Promise.await done_p;
  Client_connection.shutdown client;
  (try Eio.Flow.shutdown flow `All with _ -> ());
  !status, Buffer.contents body_buf, !client_errors, !stream_errors

let require label cond =
  if not cond then failwith ("require failed: " ^ label)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:1
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_done, server_done_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
    Fun.protect
      ~finally:(fun () -> ignore (Eio.Promise.try_resolve server_done_u ()))
      (fun () -> run_server_connection flow));
  let status, body, client_errors, stream_errors =
    Eio.Switch.run @@ fun conn_sw ->
    let flow =
      Eio.Net.connect
        ~sw:conn_sw
        net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    run_client_connection flow
  in
  Eio.Promise.await server_done;
  require "status 200" (status = Some 200);
  require "body" (String.equal body "eio-h2:/eio");
  require "no client errors" (client_errors = []);
  require "no stream errors" (stream_errors = []);
  Printf.printf "h_s1_p2_eio_tcp_get status=200 body=%S port=%d\n%!" body port
