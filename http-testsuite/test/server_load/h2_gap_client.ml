(* Tiny H2C load client for attribution of the 1-connection / 16-stream
   echo_1k tail. It intentionally records client-side checkpoints rather than
   optimizing the server path.

   Usage:
     h2_gap_client.exe HOST PORT REQUESTS CONCURRENCY REPEATS OUT.tsv [PATH]

   Set ETA_H2_GAP_TLS_CA_FILE to wrap the TCP flow in Eta TLS with ALPN h2.
   Set ETA_H2_GAP_METHOD and ETA_H2_GAP_BODY_BYTES to override the default
   POST 1024-byte request shape. *)

module H2 = Eta_http.H2
module H2_mux = Eta_http_eio.H2.Multiplexer

type sample = {
  repeat : int;
  index : int;
  mutable stream_id : int;
  mutable t0_us : int64;
  mutable t1_us : int64 option;
  mutable t2_us : int64 option;
  mutable t3_us : int64 option;
  mutable tx_ready_us : int64 option;
  mutable rx_headers_us : int64 option;
  mutable rx_body_end_us : int64 option;
  mutable rx_feed_start_us : int64 option;
  mutable rx_feed_end_us : int64 option;
  mutable status : int option;
  mutable bytes : int;
  mutable error : string option;
  mutable completed : bool;
  local_port : int;
}

type frame_scanner = {
  mutable preface_left : int;
  mutable pending : bytes;
}

let client_preface_len = String.length "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let create_scanner () = { preface_left = client_preface_len; pending = Bytes.empty }
let create_peer_scanner () = { preface_left = 0; pending = Bytes.empty }

let now_us () =
  Int64.of_float (Unix.gettimeofday () *. 1_000_000.0)

let now_ms () =
  Int64.of_float (Unix.gettimeofday () *. 1_000.0)

let local_tcp_port flow =
  match Eio_unix.Resource.fd_opt flow with
  | None -> -1
  | Some fd ->
      Eio_unix.Fd.use fd
        (fun unix_fd ->
          match Unix.getsockname unix_fd with
          | Unix.ADDR_INET (_, port) -> port
          | Unix.ADDR_UNIX _ -> -1)
        ~if_closed:(fun () -> -1)

let env_int name default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some value -> int_of_string value

let env_float name default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some value -> float_of_string value

let host_peer_name s =
  match Domain_name.of_string s with
  | Ok dn -> Domain_name.host_exn dn
  | Error (`Msg e) -> failwith ("invalid peer name: " ^ e)

let pp_client_error (error : H2.Connection.error) =
  Format.asprintf "%a:%s" H2.Error_code.pp_hum error.error_code error.message

let iovecs_to_bytes iovecs =
  let len = H2.IOVec.lengthv iovecs in
  let bytes = Bytes.create len in
  let dst_off = ref 0 in
  List.iter
    (fun ({ H2.IOVec.buffer; off; len } : Bigstringaf.t H2.IOVec.t) ->
      Bigstringaf.blit_to_bytes buffer ~src_off:off bytes ~dst_off:!dst_off
        ~len;
      dst_off := !dst_off + len)
    iovecs;
  bytes

let trim_preface scanner chunk =
  if scanner.preface_left = 0 then chunk
  else
    let len = Bytes.length chunk in
    let skip = min scanner.preface_left len in
    scanner.preface_left <- scanner.preface_left - skip;
    Bytes.sub chunk skip (len - skip)

let frame_length bytes off =
  (Char.code (Bytes.get bytes off) lsl 16)
  lor (Char.code (Bytes.get bytes (off + 1)) lsl 8)
  lor Char.code (Bytes.get bytes (off + 2))

let frame_stream_id bytes off =
  ((Char.code (Bytes.get bytes (off + 5)) land 0x7f) lsl 24)
  lor (Char.code (Bytes.get bytes (off + 6)) lsl 16)
  lor (Char.code (Bytes.get bytes (off + 7)) lsl 8)
  lor Char.code (Bytes.get bytes (off + 8))

let scan_outgoing_request_complete scanner chunk =
  let chunk = trim_preface scanner chunk in
  if Bytes.length chunk > 0 then
    scanner.pending <- Bytes.cat scanner.pending chunk;
  let data = scanner.pending in
  let data_len = Bytes.length data in
  let rec loop off acc =
    if data_len - off < 9 then (off, acc)
    else
      let len = frame_length data off in
      let frame_total = 9 + len in
      if data_len - off < frame_total then (off, acc)
      else
        let frame_type = Char.code (Bytes.get data (off + 3)) in
        let flags = Char.code (Bytes.get data (off + 4)) in
        let stream_id = frame_stream_id data off in
        let acc =
          if
            (frame_type = 0x0 || frame_type = 0x1)
            && flags land 0x1 <> 0 && stream_id > 0
          then
            stream_id :: acc
          else acc
        in
        loop (off + frame_total) acc
  in
  let consumed, stream_ids = loop 0 [] in
  scanner.pending <- Bytes.sub data consumed (data_len - consumed);
  List.rev stream_ids

type incoming_event =
  | Response_headers of int
  | Response_body_end of int

let scan_incoming_frames scanner chunk =
  let chunk = trim_preface scanner chunk in
  if Bytes.length chunk > 0 then
    scanner.pending <- Bytes.cat scanner.pending chunk;
  let data = scanner.pending in
  let data_len = Bytes.length data in
  let rec loop off acc =
    if data_len - off < 9 then (off, acc)
    else
      let len = frame_length data off in
      let frame_total = 9 + len in
      if data_len - off < frame_total then (off, acc)
      else
        let frame_type = Char.code (Bytes.get data (off + 3)) in
        let flags = Char.code (Bytes.get data (off + 4)) in
        let stream_id = frame_stream_id data off in
        let acc =
          if stream_id <= 0 then acc
          else if frame_type = 0x1 then
            let acc = Response_headers stream_id :: acc in
            if flags land 0x1 <> 0 then Response_body_end stream_id :: acc
            else acc
          else if frame_type = 0x0 && flags land 0x1 <> 0 then
            Response_body_end stream_id :: acc
          else acc
        in
        loop (off + frame_total) acc
  in
  let consumed, events = loop 0 [] in
  scanner.pending <- Bytes.sub data consumed (data_len - consumed);
  List.rev events

let output_sample out sample =
  let opt_i64 = function None -> "-1" | Some value -> Int64.to_string value in
  let opt_int = function None -> "-1" | Some value -> string_of_int value in
  let error = match sample.error with None -> "" | Some value -> value in
  Printf.fprintf out
    "%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n"
    sample.repeat sample.index sample.stream_id
    (Int64.to_string sample.t0_us)
    (opt_i64 sample.t1_us) (opt_i64 sample.t2_us) (opt_i64 sample.t3_us)
    (opt_int sample.status) sample.bytes error
    (opt_i64 sample.rx_headers_us) (opt_i64 sample.rx_body_end_us)
    (opt_i64 sample.tx_ready_us)
    (opt_i64 sample.rx_feed_start_us)
    (opt_i64 sample.rx_feed_end_us)
    sample.local_port

let run_repeat ~env ~out ~host ~port ~requests ~concurrency ~repeat ~path =
  if host <> "127.0.0.1" && host <> "localhost" then
    invalid_arg "h2_gap_client: only 127.0.0.1/localhost is supported";
  let clock = Eio.Stdenv.clock env in
  let method_ =
    Sys.getenv_opt "ETA_H2_GAP_METHOD"
    |> Option.value ~default:"POST"
    |> String.uppercase_ascii
  in
  let tls_enabled = Option.is_some (Sys.getenv_opt "ETA_H2_GAP_TLS_CA_FILE") in
  let body_bytes = env_int "ETA_H2_GAP_BODY_BYTES" 1024 in
  let payload = String.make body_bytes 'x' in
  Eio.Switch.run @@ fun sw ->
  let tcp_flow =
    Eio.Net.connect ~sw (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let local_port = local_tcp_port tcp_flow in
  let flow =
    (tcp_flow :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let flow =
    match Sys.getenv_opt "ETA_H2_GAP_TLS_CA_FILE" with
    | None -> flow
    | Some ca_file ->
        let config =
          Eta_http.Tls.Config.default_client
            ~peer_name:(host_peer_name "localhost")
            ~alpn_protocols:[ "h2" ] ~ca_file ()
        in
        (Eta_http_eio.Tls.Eio.client_of_flow config flow
          :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let timeout_s = env_float "ETA_H2_GAP_TIMEOUT" 60.0 in
  let stream_samples = Hashtbl.create concurrency in
  let completed_stream = Eio.Stream.create concurrency in
  let wake_writer = ref None in
  let wake () =
    match !wake_writer with
    | None -> ()
    | Some resolver -> ignore (Eio.Promise.try_resolve resolver ())
  in
  let connection_errors = ref [] in
  let client =
    H2.Connection.Client.create
      ~error_handler:(fun error ->
        connection_errors := pp_client_error error :: !connection_errors;
        wake ())
      ()
  in
  let scanner = create_scanner () in
  let incoming_scanner = create_peer_scanner () in
  let read_buffer = Bigstringaf.create (64 * 1024) in
  let samples =
    Array.init requests (fun index ->
        {
          repeat;
          index;
          stream_id = -1;
          t0_us = 0L;
          t1_us = None;
          t2_us = None;
          t3_us = None;
          tx_ready_us = None;
          rx_headers_us = None;
          rx_body_end_us = None;
          rx_feed_start_us = None;
          rx_feed_end_us = None;
          status = None;
          bytes = 0;
          error = None;
          completed = false;
          local_port;
        })
  in
  let complete sample =
    if not sample.completed then (
      sample.completed <- true;
      Eio.Stream.add completed_stream sample.index)
  in
  let mark_error sample message =
    if Option.is_none sample.error then sample.error <- Some message;
    sample.t3_us <- Some (now_us ());
    complete sample
  in
  let rec writer_loop () =
    match H2.Connection.next_write_operation client with
    | Write iovecs ->
        let bytes = iovecs_to_bytes iovecs in
        let ready_us = now_us () in
        let request_complete_streams = scan_outgoing_request_complete scanner bytes in
        request_complete_streams
        |> List.iter (fun stream_id ->
               match Hashtbl.find_opt stream_samples stream_id with
               | None -> ()
               | Some sample when Option.is_none sample.tx_ready_us ->
                   sample.tx_ready_us <- Some ready_us
               | Some _ -> ());
        Eio.Flow.write flow [ Cstruct.of_bytes bytes ];
        let written_us = now_us () in
        let written = Bytes.length bytes in
        H2.Connection.report_write_result client (`Ok written);
        request_complete_streams
        |> List.iter (fun stream_id ->
               match Hashtbl.find_opt stream_samples stream_id with
               | None -> ()
               | Some sample when Option.is_none sample.t1_us ->
                   sample.t1_us <- Some written_us
               | Some _ -> ());
        writer_loop ()
    | Yield ->
        let promise, resolver = Eio.Promise.create () in
        wake_writer := Some resolver;
        H2.Connection.yield_writer client (fun () ->
            ignore (Eio.Promise.try_resolve resolver ()));
        Eio.Promise.await promise;
        wake_writer := None;
        writer_loop ()
    | Close _ ->
        H2.Connection.report_write_result client `Closed
  in
  let note_incoming read_us = function
    | Response_headers stream_id -> (
        match Hashtbl.find_opt stream_samples stream_id with
        | Some sample when Option.is_none sample.rx_headers_us ->
            sample.rx_headers_us <- Some read_us
        | Some _ | None -> ())
    | Response_body_end stream_id -> (
        match Hashtbl.find_opt stream_samples stream_id with
        | Some sample when Option.is_none sample.rx_body_end_us ->
            sample.rx_body_end_us <- Some read_us
        | Some _ | None -> ())
  in
  let note_feed_start feed_start_us = function
    | Response_headers stream_id | Response_body_end stream_id -> (
        match Hashtbl.find_opt stream_samples stream_id with
        | Some sample when Option.is_none sample.rx_feed_start_us ->
            sample.rx_feed_start_us <- Some feed_start_us
        | Some _ | None -> ())
  in
  let note_feed_end feed_end_us = function
    | Response_headers stream_id | Response_body_end stream_id -> (
        match Hashtbl.find_opt stream_samples stream_id with
        | Some sample when Option.is_none sample.rx_feed_end_us ->
            sample.rx_feed_end_us <- Some feed_end_us
        | Some _ | None -> ())
  in
  let rec feed_read off len =
    if len > 0 then
      let consumed = H2.Connection.read client read_buffer ~off ~len in
      if consumed <= 0 then
        connection_errors := "h2_read_consumed_zero" :: !connection_errors
      else feed_read (off + consumed) (len - consumed)
  in
  let rec reader_loop () =
    let view = Cstruct.of_bigarray read_buffer in
    match Eio.Flow.single_read flow view with
    | read ->
        let read_us = now_us () in
        let bytes = Bytes.create read in
        Bigstringaf.blit_to_bytes read_buffer ~src_off:0 bytes ~dst_off:0
          ~len:read;
        let incoming_events = scan_incoming_frames incoming_scanner bytes in
        List.iter (note_incoming read_us) incoming_events;
        let feed_start_us = now_us () in
        List.iter (note_feed_start feed_start_us) incoming_events;
        feed_read 0 read;
        let feed_end_us = now_us () in
        List.iter (note_feed_end feed_end_us) incoming_events;
        reader_loop ()
    | exception End_of_file ->
        ignore (H2.Connection.read_eof client read_buffer ~off:0 ~len:0)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try writer_loop ()
       with exn ->
         connection_errors := Printexc.to_string exn :: !connection_errors);
      `Stop_daemon);
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try reader_loop ()
       with exn ->
         connection_errors := Printexc.to_string exn :: !connection_errors);
      `Stop_daemon);
  let next_index = ref 0 in
  let completed = ref 0 in
  let open_one () =
    let index = !next_index in
    incr next_index;
    let stream_id = (index * 2) + 1 in
    let sample = samples.(index) in
    sample.stream_id <- stream_id;
    sample.t0_us <- now_us ();
    Hashtbl.replace stream_samples stream_id sample;
    let request : H2.Connection.Client.request =
      let headers =
        if body_bytes > 0 || String.equal method_ "POST" then
          [
            ("content-length", string_of_int body_bytes);
            ("content-type", "application/octet-stream");
          ]
        else []
      in
      {
        meth = method_;
        scheme = Some (if tls_enabled then "https" else "http");
        authority = Some "localhost";
        path;
        headers;
      }
    in
    try
      let end_stream = body_bytes = 0 in
      let body =
        H2.Connection.Client.request client ~stream_id ~end_stream request
          ~error_handler:(fun _stream_id error ->
            mark_error sample (pp_client_error error))
          ~response_handler:(fun _stream_id response ->
            sample.t2_us <- Some (now_us ());
            sample.status <- Some response.status;
            let rec read_body () =
              H2.Body.Reader.schedule_read response.body
                ~on_eof:(fun () ->
                  sample.t3_us <- Some (now_us ());
                  complete sample)
                ~on_read:(fun bs ~off:_ ~len ->
                  ignore bs;
                  sample.bytes <- sample.bytes + len;
                  read_body ())
            in
            read_body ())
      in
      (if not end_stream && body_bytes > 0 then
         match H2.Body.Writer.write_string body payload with
         | Ok () -> ()
         | Error error ->
             mark_error sample
               (Format.asprintf "request_body_write:%a" H2.Error_code.pp_hum
                  error));
      if not end_stream then H2.Body.Writer.close body
    with exn -> mark_error sample (Printexc.to_string exn)
  in
  let initial = min concurrency requests in
  for _ = 1 to initial do
    open_one ()
  done;
  Eio.Time.with_timeout_exn clock timeout_s (fun () ->
      while !completed < requests do
        ignore (Eio.Stream.take completed_stream);
        incr completed;
        if !next_index < requests then open_one ()
      done);
  H2.Connection.shutdown client;
  (try Eio.Flow.shutdown flow `All with _ -> ());
  Array.iter (output_sample out) samples;
  match !connection_errors with
  | [] -> ()
  | errors ->
      Printf.eprintf "repeat %d connection errors: %s\n%!" repeat
        (String.concat "; " (List.rev errors))

let usage () =
  Printf.eprintf
    "usage: %s HOST PORT REQUESTS CONCURRENCY REPEATS OUT.tsv [PATH]\n%!"
    Sys.argv.(0);
  exit 2

let positive_int name value =
  if value <= 0 then invalid_arg (name ^ " must be positive");
  value

let () =
  if Array.length Sys.argv <> 7 && Array.length Sys.argv <> 8 then usage ();
  let host = Sys.argv.(1) in
  let port = positive_int "PORT" (int_of_string Sys.argv.(2)) in
  let requests = positive_int "REQUESTS" (int_of_string Sys.argv.(3)) in
  let concurrency = positive_int "CONCURRENCY" (int_of_string Sys.argv.(4)) in
  let repeats = positive_int "REPEATS" (int_of_string Sys.argv.(5)) in
  let out_path = Sys.argv.(6) in
  let path = if Array.length Sys.argv = 8 then Sys.argv.(7) else "/echo" in
  Eio_main.run @@ fun env ->
  Out_channel.with_open_text out_path @@ fun out ->
  Printf.fprintf out
    "repeat\tindex\tstream_id\tt0_us\tt1_us\tt2_us\tt3_us\tstatus\tbytes\terror\trx_headers_us\trx_body_end_us\ttx_ready_us\trx_feed_start_us\trx_feed_end_us\tlocal_port\n";
  for repeat = 1 to repeats do
    run_repeat ~env ~out ~host ~port ~requests ~concurrency ~repeat ~path
  done
