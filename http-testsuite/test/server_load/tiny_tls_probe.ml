(* Direct tiny write probe for H2 TLS spread-tail attribution.

   Server:
     tiny_tls_probe.exe server PORT TEMP_DIR tls|plain

   Client:
     tiny_tls_probe.exe client HOST PORT REQUESTS CONNECTIONS REPEATS OUT.tsv tls|plain [CA_FILE]

   Protocol: each request is one byte; each response is 14 bytes. Connections
   run one request at a time, matching the H2 spread shape's one active stream
   per connection. *)

let response = Cstruct.of_string "123456789abcde"
let request = Cstruct.of_string "x"

type mode = TLS | Plain

type sample = {
  repeat : int;
  index : int;
  connection : int;
  mutable t0_us : int64;
  mutable t1_us : int64 option;
  mutable t2_us : int64 option;
  mutable error : string option;
}

let now_us () = Int64.of_float (Unix.gettimeofday () *. 1_000_000.0)

let usage () =
  Printf.eprintf
    "usage:\n  %s server PORT TEMP_DIR tls|plain\n  %s client HOST PORT \
     REQUESTS CONNECTIONS REPEATS OUT.tsv tls|plain [CA_FILE]\n%!"
    Sys.argv.(0) Sys.argv.(0);
  exit 2

let parse_mode = function
  | "tls" -> TLS
  | "plain" -> Plain
  | other -> invalid_arg ("mode must be tls or plain, got " ^ other)

let positive_int name value =
  if value <= 0 then invalid_arg (name ^ " must be positive");
  value

let env_bool name default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some value -> (
      match String.lowercase_ascii (String.trim value) with
      | "0" | "false" | "no" | "off" -> false
      | _ -> true)

let set_tcp_nodelay flow =
  match Eio_unix.Resource.fd_opt flow with
  | None -> ()
  | Some fd ->
      Eio_unix.Fd.use fd
        (fun unix_fd -> Unix.setsockopt unix_fd Unix.TCP_NODELAY true)
        ~if_closed:(fun () -> ())

let host_peer_name s =
  match Domain_name.of_string s with
  | Ok dn -> Domain_name.host_exn dn
  | Error (`Msg e) -> failwith ("invalid peer name: " ^ e)

let trace_path = lazy (Sys.getenv_opt "ETA_TINY_TLS_TRACE_PATH")

let trace_line line =
  match Lazy.force trace_path with
  | None -> ()
  | Some path ->
      let out =
        open_out_gen [ Open_creat; Open_append; Open_text ] 0o644 path
      in
      Fun.protect
        ~finally:(fun () -> close_out_noerr out)
        (fun () ->
          output_string out line;
          output_char out '\n')

let read_exact flow bytes =
  let buf = Cstruct.create bytes in
  let rec loop off =
    if off < bytes then
      let n = Eio.Flow.single_read flow (Cstruct.sub buf off (bytes - off)) in
      if n = 0 then raise End_of_file else loop (off + n)
  in
  loop 0

let wrap_server_flow mode tls_context flow =
  set_tcp_nodelay flow;
  let flow =
    (flow :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  match (mode, tls_context) with
  | Plain, _ -> flow
  | TLS, Some tls_context ->
      let tls_flow, _epoch =
        Eta_http_eio.Tls.Eio.server_of_flow_with_context tls_context flow
      in
      (tls_flow
        :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  | TLS, None -> invalid_arg "TLS server requires a TLS context"

let write_response ?enqueued_us mode flow =
  let started = now_us () in
  Eio.Flow.write flow [ response ];
  let completed = now_us () in
  let queue_wait_us =
    match enqueued_us with
    | None -> 0L
    | Some enqueued_us -> Int64.sub started enqueued_us
  in
  trace_line
    (Printf.sprintf
       "tiny_write mode=%s bytes=%d queue_wait_us=%Ld duration_us=%Ld"
       (match mode with TLS -> "tls" | Plain -> "plain")
       (Cstruct.length response) queue_wait_us
       Int64.(sub completed started))

let handle_server_connection mode tls_context flow _peer =
  let flow = wrap_server_flow mode tls_context flow in
  let scratch = Cstruct.create 4096 in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> ()
    | n ->
        for _ = 1 to n do
          write_response mode flow
        done;
        loop ()
    | exception End_of_file -> ()
  in
  loop ()

type server_event = Write_one of int64 | Close_writer

let handle_server_connection_split mode tls_context flow _peer =
  let flow = wrap_server_flow mode tls_context flow in
  let scratch = Cstruct.create 4096 in
  Eio.Switch.run @@ fun sw ->
  let writes = Eio.Stream.create 4096 in
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        match Eio.Stream.take writes with
        | Write_one enqueued_us ->
            write_response ~enqueued_us mode flow;
            loop ()
        | Close_writer -> ()
      in
      loop ());
  let rec read_loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> Eio.Stream.add writes Close_writer
    | n ->
        for _ = 1 to n do
          Eio.Stream.add writes (Write_one (now_us ()))
        done;
        read_loop ()
    | exception End_of_file -> Eio.Stream.add writes Close_writer
  in
  read_loop ()

let run_server ~port ~temp_dir ~mode =
  ignore (Eta_http_testsuite.Fixtures.generate ~dir:temp_dir);
  let tls_context =
    match mode with
    | Plain -> None
    | TLS -> (
        match Eta_http_testsuite.Certs.prepare ~temp_dir with
        | Error e ->
            prerr_endline ("cert prep failed: " ^ e);
            exit 1
        | Ok cert_dir ->
            let tls_config =
              Eta_http.Tls.Config.default_server
                ~certificate_chain_file:(Eta_http_testsuite.Certs.cert_path cert_dir)
                ~private_key_file:(Eta_http_testsuite.Certs.key_path cert_dir)
                ~alpn_protocols:[ "eta-tiny" ] ()
            in
            Some (Eta_http_eio.Tls.Eio.server_context tls_config))
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4096 (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Printf.printf "READY %d\n%!" port;
  Eio.Net.run_server socket ~max_connections:4096
    ~on_error:(fun exn ->
      Printf.eprintf "tiny_tls_probe server error: %s\n%!"
        (Printexc.to_string exn))
    (fun flow peer ->
      if env_bool "ETA_TINY_TLS_SPLIT_SERVER" false then
        handle_server_connection_split mode tls_context flow peer
      else handle_server_connection mode tls_context flow peer)

let wrap_client_flow mode ?ca_file flow =
  set_tcp_nodelay flow;
  let flow =
    (flow :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  match mode with
  | Plain -> flow
  | TLS ->
      let ca_file =
        match ca_file with
        | Some path -> path
        | None -> invalid_arg "TLS client requires CA_FILE"
      in
      let config =
        Eta_http.Tls.Config.default_client
          ~peer_name:(host_peer_name "localhost")
          ~alpn_protocols:[ "eta-tiny" ] ~ca_file ()
      in
      (Eta_http_eio.Tls.Eio.client_of_flow config flow
        :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)

let create_samples ~repeat ~requests =
  Array.init requests (fun index ->
      {
        repeat;
        index;
        connection = -1;
        t0_us = 0L;
        t1_us = None;
        t2_us = None;
        error = None;
      })

let run_client_repeat ~env ~host ~port ~requests ~connections ~repeat ~mode
    ?ca_file () =
  if host <> "127.0.0.1" && host <> "localhost" then
    invalid_arg "tiny_tls_probe: only 127.0.0.1/localhost is supported";
  let samples = create_samples ~repeat ~requests in
  Eio.Switch.run @@ fun sw ->
  for connection = 0 to connections - 1 do
    Eio.Fiber.fork ~sw (fun () ->
        let flow =
          Eio.Net.connect ~sw (Eio.Stdenv.net env)
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
        in
        let flow = wrap_client_flow mode ?ca_file flow in
        let rec loop index =
          if index < requests then (
            let sample = samples.(index) in
            let sample = { sample with connection } in
            samples.(index) <- sample;
            sample.t0_us <- now_us ();
            (try
               Eio.Flow.write flow [ request ];
               sample.t1_us <- Some (now_us ());
               read_exact flow (Cstruct.length response);
               sample.t2_us <- Some (now_us ())
             with exn ->
               sample.error <- Some (Printexc.to_string exn);
               sample.t2_us <- Some (now_us ()));
            loop (index + connections))
        in
        Fun.protect
          ~finally:(fun () -> try Eio.Flow.close flow with _ -> ())
          (fun () -> loop connection))
  done;
  samples

let output_sample out sample =
  let opt_i64 = function None -> "-1" | Some value -> Int64.to_string value in
  let error = match sample.error with None -> "" | Some value -> value in
  Printf.fprintf out "%d\t%d\t%d\t%Ld\t%s\t%s\t%s\n" sample.repeat sample.index
    sample.connection sample.t0_us (opt_i64 sample.t1_us)
    (opt_i64 sample.t2_us) error

let run_client ~host ~port ~requests ~connections ~repeats ~out_path ~mode
    ?ca_file () =
  Eio_main.run @@ fun env ->
  Out_channel.with_open_text out_path @@ fun out ->
  Printf.fprintf out "repeat\tindex\tconnection\tt0_us\tt1_us\tt2_us\terror\n";
  for repeat = 1 to repeats do
    let samples =
      run_client_repeat ~env ~host ~port ~requests ~connections ~repeat ~mode
        ?ca_file ()
    in
    Array.iter (output_sample out) samples
  done

let () =
  match Array.to_list Sys.argv with
  | [ _; "server"; port; temp_dir; mode ] ->
      run_server ~port:(positive_int "PORT" (int_of_string port)) ~temp_dir
        ~mode:(parse_mode mode)
  | [ _; "client"; host; port; requests; connections; repeats; out_path; mode ]
    ->
      run_client ~host ~port:(positive_int "PORT" (int_of_string port))
        ~requests:(positive_int "REQUESTS" (int_of_string requests))
        ~connections:(positive_int "CONNECTIONS" (int_of_string connections))
        ~repeats:(positive_int "REPEATS" (int_of_string repeats))
        ~out_path ~mode:(parse_mode mode) ()
  | [ _;
      "client";
      host;
      port;
      requests;
      connections;
      repeats;
      out_path;
      mode;
      ca_file ] ->
      run_client ~host ~port:(positive_int "PORT" (int_of_string port))
        ~requests:(positive_int "REQUESTS" (int_of_string requests))
        ~connections:(positive_int "CONNECTIONS" (int_of_string connections))
        ~repeats:(positive_int "REPEATS" (int_of_string repeats))
        ~out_path ~mode:(parse_mode mode) ~ca_file ()
  | _ -> usage ()
