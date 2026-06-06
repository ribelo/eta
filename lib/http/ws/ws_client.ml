(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Header = Header
module Url = Url
module Connect = Connect

type ws_error =
  [ `Connect of string
  | `Upgrade_failed of int
  | `Closed of int * string
  | `Protocol of string
  | `Timeout
  ]

type message = [ `Text of string | `Binary of bytes ]
type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type t = {
  flow : flow;
  incoming : (message, ws_error) Queue.t;
  write_mutex : Eio.Mutex.t;
  close_sent : bool Atomic.t;
  selected_protocol : string option;
}

let max_header_bytes = 32 * 1024
let read_chunk_size = 4096

let close_flow flow = try Eio.Flow.close flow with _ -> ()

let http_error_to_connect error =
  `Connect (Format.asprintf "%a" Error.pp error)

let map_http_error eff =
  Effect.catch (fun error -> Effect.fail (http_error_to_connect error)) eff

let http_url_of_ws_url raw =
  let rewrite prefix replacement =
    replacement
    ^ String.sub raw (String.length prefix) (String.length raw - String.length prefix)
  in
  if Eta.String_helpers.starts_with raw ~prefix:"ws://" then
    Ok (rewrite "ws://" "http://")
  else if Eta.String_helpers.starts_with raw ~prefix:"wss://" then
    Ok (rewrite "wss://" "https://")
  else Error (`Connect "WebSocket URL must use ws:// or wss://")

let parse_url raw =
  match http_url_of_ws_url raw with
  | Error _ as error -> error
  | Ok http_raw -> (
      match Url.parse http_raw with
      | Ok url -> Ok url
      | Error error -> Error (`Connect (Url.parse_error_to_string error)))

let trim = Eta.String_helpers.trim

let find_header_end_buffer buffer start =
  let len = Buffer.length buffer in
  let rec loop index =
    if index + 3 >= len then None
    else if Char.equal (Buffer.nth buffer index) '\r'
            && Char.equal (Buffer.nth buffer (index + 1)) '\n'
            && Char.equal (Buffer.nth buffer (index + 2)) '\r'
            && Char.equal (Buffer.nth buffer (index + 3)) '\n'
    then Some index
    else loop (index + 1)
  in
  loop (max 0 start)

type response_head = {
  status : int;
  headers : Header.t;
  initial : bytes;
}

let parse_status_line line =
  let len = String.length line in
  let first_space = String.index_opt line ' ' in
  match first_space with
  | None -> Error (`Protocol "invalid HTTP response status line")
  | Some first_space ->
      if not (Eta.String_helpers.starts_with_at line ~offset:0 "HTTP/") then
        Error (`Protocol "invalid HTTP response status line")
      else
        let status_start = first_space + 1 in
        let status_stop = ref status_start in
        while !status_stop < len && not (Char.equal line.[!status_stop] ' ') do
          incr status_stop
        done;
        let status = String.sub line status_start (!status_stop - status_start) in
        match int_of_string_opt status with
        | Some status when status >= 100 && status <= 599 -> Ok status
        | _ -> Error (`Protocol ("invalid HTTP status " ^ status))

let parse_header_line line =
  match String.index_opt line ':' with
  | None -> Error (`Protocol ("invalid HTTP header line " ^ line))
  | Some index ->
      let name_start = Eta.String_helpers.trim_left line 0 index in
      let name_stop = Eta.String_helpers.trim_right line name_start index in
      let name = String.sub line name_start (name_stop - name_start) in
      let value_start =
        Eta.String_helpers.trim_left line (index + 1) (String.length line)
      in
      let value_stop =
        Eta.String_helpers.trim_right line value_start (String.length line)
      in
      let value =
        String.sub line value_start (value_stop - value_start)
      in
      Ok (name, value)

let parse_response_head raw initial =
  let line_end raw start =
    match String.index_from_opt raw start '\n' with
    | None -> String.length raw
    | Some index ->
        if index > start && Char.equal raw.[index - 1] '\r' then index - 1
        else index
  in
  let next_start raw stop =
    if stop < String.length raw && Char.equal raw.[stop] '\r' then stop + 2
    else stop + 1
  in
  if String.length raw = 0 then Error (`Protocol "empty HTTP response")
  else
    let status_stop = line_end raw 0 in
    let status_line = String.sub raw 0 status_stop in
    match parse_status_line status_line with
    | Error _ as error -> error
    | Ok status ->
        let rec collect acc start =
          if start >= String.length raw then Ok (List.rev acc)
          else
            let stop = line_end raw start in
            if stop = start then collect acc (next_start raw stop)
            else
              let line = String.sub raw start (stop - start) in
              match parse_header_line line with
              | Ok header -> collect (header :: acc) (next_start raw stop)
              | Error _ as error -> error
        in
        Result.map
          (fun headers -> { status; headers = Header.unsafe_of_list headers; initial })
          (collect [] (next_start raw status_stop))

let read_response_head flow =
  let scratch = Cstruct.create read_chunk_size in
  let buffer = Buffer.create 512 in
  let parse_at header_end =
    let contents = Buffer.contents buffer in
    let initial_start = header_end + 4 in
    let initial_len = String.length contents - initial_start in
    let initial =
      Bytes.of_string (String.sub contents initial_start initial_len)
    in
    parse_response_head (String.sub contents 0 header_end) initial
  in
  let rec loop used =
    if used > max_header_bytes then
      Error (`Protocol "WebSocket upgrade response headers too large")
    else
      try
        let read = Eio.Flow.single_read flow scratch in
        if read = 0 then Error (`Protocol "WebSocket upgrade response ended early")
        else (
          Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 read));
          let total = used + read in
          if total > max_header_bytes then
            Error (`Protocol "WebSocket upgrade response headers too large")
          else
            match find_header_end_buffer buffer (used - 3) with
            | Some header_end -> parse_at header_end
            | None -> loop total)
      with exn -> Error (`Connect (Printexc.to_string exn))
  in
  loop 0

let add_header buffer (name, value) =
  Buffer.add_string buffer name;
  Buffer.add_string buffer ": ";
  Buffer.add_string buffer value;
  Buffer.add_string buffer "\r\n"

let write_upgrade_request flow ?(headers = Header.empty) ?(protocols = []) url key =
  if not (Header.valid headers) then Error (`Protocol "invalid WebSocket request header")
  else
    let buffer = Buffer.create 512 in
    Buffer.add_string buffer "GET ";
    Buffer.add_string buffer (Url.origin_form url);
    Buffer.add_string buffer " HTTP/1.1\r\n";
    add_header buffer ("Host", Url.authority url);
    add_header buffer ("Connection", "Upgrade");
    add_header buffer ("Upgrade", "websocket");
    add_header buffer ("Sec-WebSocket-Version", "13");
    add_header buffer ("Sec-WebSocket-Key", key);
    (match protocols with
    | [] -> ()
    | protocols -> add_header buffer ("Sec-WebSocket-Protocol", String.concat ", " protocols));
    List.iter (add_header buffer) (Header.to_list headers);
    Buffer.add_string buffer "\r\n";
    try
      Eio.Flow.copy_string (Buffer.contents buffer) flow;
      Ok ()
    with exn -> Error (`Connect (Printexc.to_string exn))

let validate_handshake ?(protocols = []) key head =
  if head.status <> 101 then Error (`Upgrade_failed head.status)
  else
    match Header.get "upgrade" head.headers with
    | Some upgrade
      when Eta.String_helpers.trim_equal_ascii_ci_bounds upgrade 0
             (String.length upgrade) "websocket" -> (
        match Header.get "connection" head.headers with
        | Some connection
          when Eta.String_helpers.contains_token_ascii_ci connection "upgrade" -> (
            let expected = Codec.accept_key key in
            match Header.get "sec-websocket-accept" head.headers with
            | Some actual when String.equal (trim actual) expected ->
                let selected = Option.map trim (Header.get "sec-websocket-protocol" head.headers) in
                (match selected with
                | None -> Ok None
                | Some protocol when List.exists (String.equal protocol) protocols ->
                    Ok selected
                | Some protocol ->
                    Error (`Protocol ("unexpected WebSocket subprotocol " ^ protocol)))
            | Some _ -> Error (`Protocol "invalid Sec-WebSocket-Accept")
            | None -> Error (`Protocol "missing Sec-WebSocket-Accept"))
        | _ -> Error (`Protocol "missing Connection: Upgrade"))
    | _ -> Error (`Protocol "missing Upgrade: websocket")

type frame_reader = {
  flow : flow;
  mutable initial : bytes;
  mutable initial_off : int;
  scratch : Cstruct.t;
  max_frame_size : int;
}

let default_max_frame_size = 1_048_576

let check_max_frame_size max_frame_size =
  if max_frame_size < 0 then
    invalid_arg "Eta_http.Ws.Client: max_frame_size must be >= 0"

let bytes_concat4 a b c d =
  let a_len = Bytes.length a in
  let b_len = Bytes.length b in
  let c_len = Bytes.length c in
  let d_len = Bytes.length d in
  let len = a_len + b_len + c_len + d_len in
  let out = Bytes.create len in
  Bytes.blit a 0 out 0 a_len;
  Bytes.blit b 0 out a_len b_len;
  Bytes.blit c 0 out (a_len + b_len) c_len;
  Bytes.blit d 0 out (a_len + b_len + c_len) d_len;
  out

let read_exact reader len =
  let out = Bytes.create len in
  let rec loop off =
    if off = len then Ok out
    else
      let pending = Bytes.length reader.initial - reader.initial_off in
      if pending > 0 then (
        let take = min pending (len - off) in
        Bytes.blit reader.initial reader.initial_off out off take;
        reader.initial_off <- reader.initial_off + take;
        loop (off + take))
      else
        try
          let want = min (len - off) (Cstruct.length reader.scratch) in
          let read =
            Eio.Flow.single_read reader.flow (Cstruct.sub reader.scratch 0 want)
          in
          if read = 0 then Error (`Protocol "unexpected WebSocket EOF")
          else (
            Cstruct.blit_to_bytes reader.scratch 0 out off read;
            loop (off + read))
        with End_of_file -> Error (`Protocol "unexpected WebSocket EOF")
           | exn -> Error (`Protocol (Printexc.to_string exn))
  in
  loop 0

let payload_length ~max_frame_size header ext =
  let b1 = Char.code (Bytes.get header 1) in
  let check len64 =
    if Int64.compare len64 (Int64.of_int max_frame_size) > 0 then
      Error (`Protocol "WebSocket frame payload exceeds max_frame_size")
    else if Int64.compare len64 (Int64.of_int Sys.max_string_length) > 0 then
      Error (`Protocol "WebSocket payload too large")
    else Ok (Int64.to_int len64)
  in
  match b1 land 0x7f with
  | value when value < 126 -> check (Int64.of_int value)
  | 126 ->
      check
        (Int64.of_int
           ((Char.code (Bytes.get ext 0) lsl 8)
           lor Char.code (Bytes.get ext 1)))
  | _ ->
      let value = ref 0L in
      for index = 0 to 7 do
        value :=
          Int64.logor
            (Int64.shift_left !value 8)
            (Int64.of_int (Char.code (Bytes.get ext index)))
      done;
      check !value

let read_frame reader =
  match read_exact reader 2 with
  | Error _ as error -> error
  | Ok header ->
      let b1 = Char.code (Bytes.get header 1) in
      let len_code = b1 land 0x7f in
      let ext_len = if len_code < 126 then 0 else if len_code = 126 then 2 else 8 in
      let mask_len = if b1 land 0x80 = 0 then 0 else 4 in
      (match read_exact reader ext_len with
      | Error _ as error -> error
      | Ok ext -> (
          match payload_length ~max_frame_size:reader.max_frame_size header ext with
          | Error _ as error -> error
          | Ok payload_len -> (
              match read_exact reader mask_len with
              | Error _ as error -> error
              | Ok mask -> (
                  match read_exact reader payload_len with
                  | Error _ as error -> error
                  | Ok payload -> (
                      match Codec.decode ~masked:false (bytes_concat4 header ext mask payload) with
                      | Ok (frame, _consumed) -> Ok frame
                      | Error error -> Error (`Protocol (Codec.parse_error_to_string error)))))))

let with_write_lock t (f) =
  Eio.Mutex.lock t.write_mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.write_mutex) f

let random_mask () = Openssl.random_bytes 4

let send_frame_sync ?(allow_after_close = false) t frame =
  try
    with_write_lock t @@ fun () ->
    (* [close_sent] is atomic because close publishes before waiting on the
       write mutex; queued senders must observe it after taking the lock. *)
    if Atomic.get t.close_sent && not allow_after_close then
      Error (`Closed (1000, "WebSocket is closing"))
    else
      let encoded = Codec.encode ~mask:(random_mask ()) frame in
      Eio.Flow.copy_string (Bytes.to_string encoded) t.flow;
      Ok ()
  with Invalid_argument message -> Error (`Protocol message)
     | exn -> Error (`Closed (1006, Printexc.to_string exn))

let send_frame ?allow_after_close t frame =
  Effect.sync (fun () -> send_frame_sync ?allow_after_close t frame)
  |> Effect.bind (function Ok () -> Effect.unit | Error error -> Effect.fail error)

let close_payload ?code ?(reason = "") () =
  match code with
  | None -> Ok Bytes.empty
  | Some code ->
      if code < 1000 || code > 4999 then Error (`Protocol "invalid WebSocket close code")
      else if String.length reason > 123 then
        Error (`Protocol "WebSocket close reason exceeds 123 bytes")
      else
        let payload = Bytes.create (2 + String.length reason) in
        Bytes.set payload 0 (Char.chr ((code lsr 8) land 0xff));
        Bytes.set payload 1 (Char.chr (code land 0xff));
        Bytes.blit_string reason 0 payload 2 (String.length reason);
        Ok payload

let send_close_frame_sync ?code ?reason t =
  match close_payload ?code ?reason () with
  | Error _ as error -> error
  | Ok payload ->
      Atomic.set t.close_sent true;
      send_frame_sync ~allow_after_close:true t
        { Codec.fin = true; opcode = Close; payload }

let send_close_frame ?code ?reason t =
  Effect.sync (fun () -> send_close_frame_sync ?code ?reason t)
  |> Effect.bind (function Ok () -> Effect.unit | Error error -> Effect.fail error)

let queue_close_error t error = Queue.close_with_error t.incoming error

let enqueue t message =
  Queue.send t.incoming message
  |> Effect.catch (function `Closed | `Closed_with_error _ -> Effect.unit)

let close_queue_for_peer_close t code reason =
  match code with
  | 1000 | 1001 -> Queue.close t.incoming
  | _ -> queue_close_error t (`Closed (code, reason))

let parse_close_payload payload =
  let len = Bytes.length payload in
  if len = 0 then Ok (1000, "")
  else if len = 1 then Error (`Protocol "invalid one-byte WebSocket close payload")
  else
    let code =
      (Char.code (Bytes.get payload 0) lsl 8) lor Char.code (Bytes.get payload 1)
    in
    let reason = Bytes.sub_string payload 2 (len - 2) in
    Ok (code, reason)

type fragment = {
  opcode : Codec.opcode;
  buffer : Buffer.t;
}

let message_of_payload opcode payload =
  match opcode with
  | Codec.Text -> Some (`Text (Bytes.to_string payload))
  | Binary -> Some (`Binary payload)
  | Continuation | Close | Ping | Pong -> None

let fail_reader t error =
  queue_close_error t error;
  close_flow t.flow;
  Effect.unit

let rec reader_loop t reader fragment =
  Effect.sync (fun () -> read_frame reader)
  |> Effect.bind (function
       | Error error -> fail_reader t error
       | Ok frame -> handle_frame t reader fragment frame)

and handle_frame t reader fragment frame =
  match frame.Codec.opcode with
  | Text | Binary -> handle_data_frame t reader fragment frame
  | Continuation -> handle_continuation t reader fragment frame
  | Ping ->
      send_frame t { Codec.fin = true; opcode = Pong; payload = frame.payload }
      |> Effect.bind (fun () -> reader_loop t reader fragment)
  | Pong -> reader_loop t reader fragment
  | Close -> (
      match parse_close_payload frame.payload with
      | Error error -> fail_reader t error
      | Ok (code, reason) ->
          let _ = send_close_frame_sync ~code ~reason t in
          close_queue_for_peer_close t code reason;
          close_flow t.flow;
          Effect.unit)

and handle_data_frame t reader fragment frame =
  match fragment with
  | Some _ -> fail_reader t (`Protocol "new data frame before final continuation")
  | None ->
      if frame.fin then
        match message_of_payload frame.opcode frame.payload with
        | None -> fail_reader t (`Protocol "invalid data frame opcode")
        | Some message -> enqueue t message |> Effect.bind (fun () -> reader_loop t reader None)
      else
        let buffer = Buffer.create (Bytes.length frame.payload) in
        Buffer.add_bytes buffer frame.payload;
        reader_loop t reader (Some { opcode = frame.opcode; buffer })

and handle_continuation t reader fragment frame =
  match fragment with
  | None -> fail_reader t (`Protocol "continuation without initial data frame")
  | Some fragment ->
      Buffer.add_bytes fragment.buffer frame.payload;
      if frame.fin then
        let payload = Bytes.of_string (Buffer.contents fragment.buffer) in
        match message_of_payload fragment.opcode payload with
        | None -> fail_reader t (`Protocol "invalid continuation opcode")
        | Some message -> enqueue t message |> Effect.bind (fun () -> reader_loop t reader None)
      else reader_loop t reader (Some fragment)

let make_connection ~flow ~selected_protocol ~max_frame_size initial =
  let t =
    {
      flow;
      incoming = Queue.create ();
      write_mutex = Eio.Mutex.create ();
      close_sent = Atomic.make false;
      selected_protocol;
    }
  in
  let reader =
    {
      flow;
      initial;
      initial_off = 0;
      scratch = Cstruct.create read_chunk_size;
      max_frame_size;
    }
  in
  Effect.daemon (reader_loop t reader None) |> Effect.map (fun () -> t)

let connect_on_flow ?(key = Codec.random_key ())
    ?(max_frame_size = default_max_frame_size) ?headers ?protocols ~sw:_ ~flow
    url =
  check_max_frame_size max_frame_size;
  let open Effect in
  let connect =
    sync (fun () -> write_upgrade_request flow ?headers ?protocols url key)
    |> bind (function Ok () -> unit | Error error -> fail error)
    |> bind (fun () ->
           sync (fun () -> read_response_head flow)
           |> bind (function Ok head -> pure head | Error error -> fail error))
    |> bind (fun head ->
           match validate_handshake ?protocols key head with
           | Ok selected_protocol ->
               make_connection ~flow ~selected_protocol ~max_frame_size
                 head.initial
           | Error error -> fail error)
  in
  connect
  |> catch (fun error ->
         sync (fun () -> close_flow flow) |> bind (fun () -> fail error))

let connect ?ca_file ?key ?max_frame_size ?headers ?protocols ~sw ~net raw_url =
  match parse_url raw_url with
  | Error error -> Effect.fail error
  | Ok url ->
      let target = Connect.target_of_url url in
      Connect.connect_tcp ~sw ~net ~method_:"GET" target
      |> map_http_error
      |> Effect.bind (fun tcp ->
             match Url.scheme url with
             | Http ->
                 connect_on_flow ?key ?max_frame_size ?headers ?protocols ~sw
                   ~flow:tcp url
             | Https ->
                 Connect.connect_tls ~alpn_protocols:[ "http/1.1" ] ?ca_file
                   ~method_:"GET" target tcp
                 |> map_http_error
                 |> Effect.bind (fun (tls, _alpn) ->
                        connect_on_flow ?key ?max_frame_size ?headers
                          ?protocols ~sw ~flow:tls url))

let incoming t = Eta_stream.Stream.from_queue t.incoming
let selected_protocol t = t.selected_protocol

let send_text t text =
  send_frame t { Codec.fin = true; opcode = Text; payload = Bytes.of_string text }

let send_binary t payload =
  send_frame t { Codec.fin = true; opcode = Binary; payload }

let close ?(code = 1000) ?(reason = "") t =
  send_close_frame ~code ~reason t
  |> Effect.bind (fun () ->
         Effect.sync (fun () ->
             Queue.close t.incoming;
             close_flow t.flow))
