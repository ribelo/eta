open Eta

type client_outcome =
  | Timed_out
  | Interrupted
  | Other_error of string
  | Completed

type server_mode =
  | Drain_only
  | Write_then_drain of string
  | Sleep_then_drain of float

let fd_count () =
  try Array.length (Sys.readdir "/proc/self/fd") with
  | Sys_error _ -> -1

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listener"

let loopback = Eio.Net.Ipaddr.V4.loopback

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let accept_all ?ip:_ ~host:_ _certs = Ok None

let read_exact flow len =
  let buf = Cstruct.create len in
  let rec loop off =
    if off = len
    then ()
    else (
      let slice = Cstruct.sub buf off (len - off) in
      match Eio.Flow.single_read flow slice with
      | 0 -> raise End_of_file
      | n -> loop (off + n))
  in
  loop 0

let drain flow =
  let buf = Cstruct.create 4096 in
  let rec loop total =
    match Eio.Flow.single_read flow buf with
    | 0 -> total
    | n -> loop (total + n)
    | exception End_of_file -> total
    | exception Eio.Io _ -> total
  in
  loop 0

let classify = function
  | Exit.Error (Cause.Fail `Timeout) -> Timed_out
  | Exit.Error (Cause.Interrupt _) -> Interrupted
  | Exit.Error cause ->
      Other_error
        (Format.asprintf "%a"
           (Cause.pp (fun fmt (`Timeout : [ `Timeout ]) ->
              Format.pp_print_string fmt "Timeout"))
           cause)
  | Exit.Ok () -> Completed

let string_of_outcome = function
  | Timed_out -> "timeout"
  | Interrupted -> "interrupt"
  | Other_error msg -> "other_error:" ^ msg
  | Completed -> "completed"

let outcome_pass = function
  | Timed_out -> true
  | Interrupted | Other_error _ | Completed -> false

let await_server clock promise =
  match Eio.Time.with_timeout clock 1.0 (fun () -> Ok (Eio.Promise.await promise)) with
  | Ok result -> result
  | Error `Timeout -> Error "server_wait_timeout"

let run_row env ~name ~server_mode client =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let rt = Runtime.create ~sw ~clock () in
  let listener =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:1
      net
      (`Tcp (loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr listener) in
  let server_done, resolve_server = Eio.Promise.create () in
  let active_server_fibers = ref 0 in
  Eio.Fiber.fork ~sw (fun () ->
    incr active_server_fibers;
    let result =
      try
        Eio.Switch.run @@ fun conn_sw ->
        let flow, _addr = Eio.Net.accept ~sw:conn_sw listener in
        (match server_mode with
         | Drain_only -> ()
         | Write_then_drain bytes -> Eio.Flow.copy_string bytes flow
         | Sleep_then_drain seconds -> Eio.Time.sleep clock seconds);
        let bytes = drain flow in
        Ok bytes
      with exn -> Error (Printexc.to_string exn)
    in
    decr active_server_fibers;
    ignore (Eio.Promise.try_resolve resolve_server result));
  Eio.Fiber.yield ();
  let before_fd = fd_count () in
  let before_fibers = !active_server_fibers in
  let permit = ref 0 in
  incr permit;
  let effect =
    Effect.named name
      (Effect.sync (fun () ->
      Fun.protect
        ~finally:(fun () -> decr permit)
        (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow = Eio.Net.connect ~sw:client_sw net (`Tcp (loopback, port)) in
          client flow))
      )
    |> Effect.timeout (Duration.ms 50)
  in
  let outcome = classify (Runtime.run rt effect) in
  let server_result = await_server clock server_done in
  let after_fd = fd_count () in
  let after_fibers = !active_server_fibers in
  let server_closed =
    match server_result with
    | Ok _ -> true
    | Error _ -> false
  in
  let server_detail =
    match server_result with
    | Ok bytes -> "bytes=" ^ string_of_int bytes
    | Error msg -> msg
  in
  Printf.printf
    "h_s4a_network name=%s result=%s outcome=%s server_closed=%b permit=%d fd_before=%d fd_after=%d fd_delta=%d fiber_before=%d fiber_after=%d server_detail=%s\n%!"
    name
    (if outcome_pass outcome && server_closed && !permit = 0 && before_fd = after_fd
     then "PASS"
     else "FAIL")
    (string_of_outcome outcome)
    server_closed
    !permit
    before_fd
    after_fd
    (if before_fd < 0 || after_fd < 0 then 0 else after_fd - before_fd)
    before_fibers
    after_fibers
    server_detail;
  outcome

let run_saturated_connect env =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let rt = Runtime.create ~sw ~clock () in
  let listener =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:1
      net
      (`Tcp (loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr listener) in
  let fillers = ref 0 in
  let stop_reason = ref "limit" in
  for _ = 1 to 256 do
    match
      Eio.Time.with_timeout clock 0.005 (fun () ->
        Ok (Eio.Net.connect ~sw net (`Tcp (loopback, port))))
    with
    | Ok _flow -> incr fillers
    | Error `Timeout -> stop_reason := "connect_timeout"
    | exception exn -> stop_reason := "connect_error:" ^ Printexc.to_string exn
  done;
  let before_fd = fd_count () in
  let before_fibers = 0 in
  let permit = ref 0 in
  incr permit;
  let effect =
    Effect.named "tcp_connect_saturated_listener" (Effect.sync (fun () ->
      Fun.protect
        ~finally:(fun () -> decr permit)
        (fun () ->
          Eio.Switch.run @@ fun client_sw ->
          let flow =
            Eio.Net.connect ~sw:client_sw net (`Tcp (loopback, port))
          in
          Eio.Resource.close flow)))
    |> Effect.timeout (Duration.ms 50)
  in
  let outcome = classify (Runtime.run rt effect) in
  let after_fd = fd_count () in
  let after_fibers = 0 in
  let result =
    if outcome_pass outcome && !permit = 0 && before_fd = after_fd
    then "PASS"
    else
      match outcome with
      | Completed -> "UNPROVEN"
      | Timed_out | Interrupted | Other_error _ -> "FAIL"
  in
  Printf.printf
    "h_s4a_connect name=tcp_connect_saturated_listener result=%s outcome=%s filler_connected=%d stop_reason=%s permit=%d fd_before=%d fd_after=%d fd_delta=%d fiber_before=%d fiber_after=%d\n%!"
    result
    (string_of_outcome outcome)
    !fillers
    !stop_reason
    !permit
    before_fd
    after_fd
    (if before_fd < 0 || after_fd < 0 then 0 else after_fd - before_fd)
    before_fibers
    after_fibers

let tls_handshake_client flow =
  let config =
    Tls.Config.client
      ~authenticator:accept_all
      ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let tls_flow =
    Tls_eio.client_of_flow config ~host:(host_exn "stall.local") flow
  in
  ignore (Tls_eio.epoch tls_flow : (Tls.Core.epoch_data, unit) result)

let header_read_client flow =
  let buf = Cstruct.create 1 in
  ignore (Eio.Flow.single_read flow buf : int)

let body_read_client flow =
  let prefix = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhi" in
  read_exact flow (String.length prefix);
  read_exact flow 1

let upload_sink_client flow =
  let chunk = String.make (1024 * 1024) 'x' in
  for _ = 1 to 1024 do
    Eio.Flow.copy_string chunk flow
  done

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  run_saturated_connect env;
  ignore
    (run_row env ~name:"tls_handshake_stall" ~server_mode:Drain_only
       tls_handshake_client);
  ignore
    (run_row env ~name:"header_read_stall" ~server_mode:Drain_only
       header_read_client);
  let body_prefix = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhi" in
  ignore
    (run_row env ~name:"body_read_stall"
       ~server_mode:(Write_then_drain body_prefix)
       body_read_client);
  ignore
    (run_row env ~name:"upload_sink_stall"
       ~server_mode:(Sleep_then_drain 0.2)
       upload_sink_client)
