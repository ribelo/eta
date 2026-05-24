(** Raw HTTP/2 frame construction and malicious server helpers.
    Used by adversarial fixtures to craft pathological server behaviour. *)

open Eio.Std

(* ---------------------------------------------------------------------------
   HPACK mini-encoder — enough for the status-line and a few literal headers
   we need in adversarial fixtures.
   --------------------------------------------------------------------------- *)

let encode_int7 n =
  if n < 128 then [ n ]
  else
    let rec loop n acc =
      if n < 128 then n :: acc
      else loop (n lsr 7) ((128 + (n land 127)) :: acc)
    in
    loop (n - 127) [ 127 ]

let hpack_literal ~name ~value =
  let name_bytes = Bytes.of_string name in
  let value_bytes = Bytes.of_string value in
  let name_len = encode_int7 (Bytes.length name_bytes) in
  let value_len = encode_int7 (Bytes.length value_bytes) in
  let total_len = 1 + List.length name_len + Bytes.length name_bytes + List.length value_len + Bytes.length value_bytes in
  let buf = Bytes.create total_len in
  Bytes.set buf 0 '\x00'; (* literal, new name, no indexing *)
  let offset = ref 1 in
  List.iter (fun b -> Bytes.set buf !offset (Char.chr b); incr offset) name_len;
  Bytes.blit name_bytes 0 buf !offset (Bytes.length name_bytes);
  offset := !offset + Bytes.length name_bytes;
  List.iter (fun b -> Bytes.set buf !offset (Char.chr b); incr offset) value_len;
  Bytes.blit value_bytes 0 buf !offset (Bytes.length value_bytes);
  Bytes.to_string buf

let hpack_indexed_status_200 = "\x88"

(* ---------------------------------------------------------------------------
   Raw HTTP/2 frame construction
   --------------------------------------------------------------------------- *)

let frame ~ty ~flags ~stream_id payload =
  let len = String.length payload in
  let buf = Bytes.create (9 + len) in
  Bytes.set buf 0 (Char.chr (len lsr 16));
  Bytes.set buf 1 (Char.chr ((len lsr 8) land 0xFF));
  Bytes.set buf 2 (Char.chr (len land 0xFF));
  Bytes.set buf 3 (Char.chr ty);
  Bytes.set buf 4 (Char.chr flags);
  let sid = Int32.of_int stream_id in
  Bytes.set_int32_be buf 5 sid;
  Bytes.blit_string payload 0 buf 9 len;
  Bytes.to_string buf

let settings_frame ?(ack=false) pairs =
  let flags = if ack then 0x01 else 0x00 in
  let payload = Buffer.create (6 * List.length pairs) in
  List.iter (fun (id, value) ->
      Buffer.add_char payload (Char.chr (id lsr 8));
      Buffer.add_char payload (Char.chr (id land 0xFF));
      Buffer.add_char payload (Char.chr ((value lsr 24) land 0xFF));
      Buffer.add_char payload (Char.chr ((value lsr 16) land 0xFF));
      Buffer.add_char payload (Char.chr ((value lsr 8) land 0xFF));
      Buffer.add_char payload (Char.chr (value land 0xFF));
    ) pairs;
  frame ~ty:0x04 ~flags ~stream_id:0 (Buffer.contents payload)

let headers_frame ~end_headers ~stream_id block =
  let flags = if end_headers then 0x04 else 0x00 in
  frame ~ty:0x01 ~flags ~stream_id block

let continuation_frame ~end_headers ~stream_id block =
  let flags = if end_headers then 0x04 else 0x00 in
  frame ~ty:0x09 ~flags ~stream_id block

let rst_stream_frame ~stream_id error_code =
  let buf = Bytes.create 4 in
  Bytes.set_int32_be buf 0 (Int32.of_int error_code);
  frame ~ty:0x03 ~flags:0x00 ~stream_id (Bytes.to_string buf)

let goaway_frame ~last_stream_id ~error_code ?(debug="") () =
  let len = 8 + String.length debug in
  let buf = Bytes.create len in
  Bytes.set_int32_be buf 0 (Int32.logand (Int32.of_int last_stream_id) 0x7FFFFFFFl);
  Bytes.set_int32_be buf 4 (Int32.of_int error_code);
  Bytes.blit_string debug 0 buf 8 (String.length debug);
  frame ~ty:0x07 ~flags:0x00 ~stream_id:0 (Bytes.to_string buf)

let ping_frame ~ack payload =
  let flags = if ack then 0x01 else 0x00 in
  let data = String.sub payload 0 (min 8 (String.length payload)) in
  let padded = data ^ String.make (8 - String.length data) '\x00' in
  frame ~ty:0x06 ~flags ~stream_id:0 padded

let window_update_frame ~stream_id increment =
  let buf = Bytes.create 4 in
  Bytes.set_int32_be buf 0 (Int32.logand (Int32.of_int increment) 0x7FFFFFFFl);
  frame ~ty:0x08 ~flags:0x00 ~stream_id (Bytes.to_string buf)

let data_frame ~end_stream ~stream_id payload =
  let flags = if end_stream then 0x01 else 0x00 in
  frame ~ty:0x00 ~flags ~stream_id payload

(* ---------------------------------------------------------------------------
   Generic h2 malicious server lifecycle
   --------------------------------------------------------------------------- *)

let write_string flow s =
  let cs = Cstruct.of_string s in
  Eio.Flow.write flow [ cs ]

let read_preface flow =
  let buf = Cstruct.create 24 in
  let n = Eio.Flow.single_read flow buf in
  if n < 24 then failwith "short client preface"

let read_frame_header flow =
  let buf = Cstruct.create 9 in
  let n = Eio.Flow.single_read flow buf in
  if n < 9 then failwith "short frame header";
  let len = (Cstruct.get_uint8 buf 0 lsl 16) lor (Cstruct.get_uint8 buf 1 lsl 8) lor Cstruct.get_uint8 buf 2 in
  let ty = Cstruct.get_uint8 buf 3 in
  let flags = Cstruct.get_uint8 buf 4 in
  let stream_id =
    ((Cstruct.get_uint8 buf 5 land 0x7F) lsl 24)
    lor (Cstruct.get_uint8 buf 6 lsl 16)
    lor (Cstruct.get_uint8 buf 7 lsl 8)
    lor Cstruct.get_uint8 buf 8
  in
  (len, ty, flags, stream_id)

let skip_frame_payload flow len =
  if len > 0 then (
    let buf = Cstruct.create len in
    let n = Eio.Flow.single_read flow buf in
    if n < len then failwith "short frame payload")

let send_server_preface flow =
  (* Server connection preface is just a SETTINGS frame. *)
  write_string flow (settings_frame [])

let ack_settings flow =
  write_string flow (settings_frame ~ack:true [])

let with_client_stream ~env ~on_request f =
  let port = Util.random_port () in
  let server_done, resolve = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
      let net = Eio.Stdenv.net env in
      let socket = Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
              Fun.protect
                ~finally:(fun () -> ignore (Eio.Promise.try_resolve resolve ()))
                (fun () ->
                   send_server_preface flow;
                   read_preface flow;
                   (* client sends SETTINGS first; ack it *)
                   let len, ty, _flags, _sid = read_frame_header flow in
                   if ty = 0x04 then ack_settings flow
                   else skip_frame_payload flow len;
                   skip_frame_payload flow len;
                   on_request flow)));
      let result = f port in
      ignore (Eio.Promise.await server_done);
      result)

(* ---------------------------------------------------------------------------
   Attack-specific server behaviours
   --------------------------------------------------------------------------- *)

let serve_rapid_reset ~env ~count ~delay_sec flow =
  (* Wait for first client HEADERS, then HEADERS+RST on every stream. *)
  let stream_count = ref 0 in
  let rec loop () =
    if !stream_count >= count then ()
    else
      let len, ty, _flags, sid = read_frame_header flow in
      skip_frame_payload flow len;
      if ty = 0x01 then (
        incr stream_count;
        write_string flow (headers_frame ~end_headers:true ~stream_id:sid hpack_indexed_status_200);
        write_string flow (rst_stream_frame ~stream_id:sid 8);
        if delay_sec > 0.0 then Eio.Time.sleep (Eio.Stdenv.clock env) delay_sec;
        loop ())
      else loop ()
  in
  loop ()

let serve_continuation_flood ~env ~frames ~delay_sec flow =
  let len, ty, _flags, sid = read_frame_header flow in
  skip_frame_payload flow len;
  if ty = 0x01 then (
    (* send HEADERS without END_HEADERS *)
    write_string flow (headers_frame ~end_headers:false ~stream_id:sid hpack_indexed_status_200);
    (* send many CONTINUATION frames without END_HEADERS *)
    for _i = 1 to frames do
      let chunk = hpack_literal ~name:"x-continuation" ~value:"a" in
      write_string flow (continuation_frame ~end_headers:false ~stream_id:sid chunk);
      if delay_sec > 0.0 then Eio.Time.sleep (Eio.Stdenv.clock env) delay_sec
    done;
    (* final CONTINUATION with END_HEADERS, then RST_STREAM *)
    let final = hpack_literal ~name:"x-end" ~value:"done" in
    write_string flow (continuation_frame ~end_headers:true ~stream_id:sid final);
    write_string flow (rst_stream_frame ~stream_id:sid 8))

let serve_hpack_bomb ~env ~decoded_size flow =
  let len, ty, _flags, sid = read_frame_header flow in
  skip_frame_payload flow len;
  if ty = 0x01 then (
    (* Send a HEADERS block that decodes to a very large header list.
       We do this by sending many literal header fields with large values
       in a single HEADERS frame. *)
    let big_value = String.make decoded_size 'x' in
    let block = hpack_literal ~name:"x-bomb" ~value:big_value in
    write_string flow (headers_frame ~end_headers:true ~stream_id:sid block);
    write_string flow (data_frame ~end_stream:true ~stream_id:sid ""))

let serve_ping_flood ~env ~count ~delay_sec flow =
  let len, ty, _flags, _sid = read_frame_header flow in
  skip_frame_payload flow len;
  for _i = 1 to count do
    write_string flow (ping_frame ~ack:false "pingflood");
    if delay_sec > 0.0 then Eio.Time.sleep (Eio.Stdenv.clock env) delay_sec
  done

let serve_settings_flood ~env ~count ~delay_sec flow =
  let len, ty, _flags, _sid = read_frame_header flow in
  skip_frame_payload flow len;
  for _i = 1 to count do
    write_string flow (settings_frame [ (0x3, 100 ); (0x4, 65535) ]);
    if delay_sec > 0.0 then Eio.Time.sleep (Eio.Stdenv.clock env) delay_sec
  done

let serve_empty_frames_flood ~env ~count ~delay_sec flow =
  let len, ty, _flags, sid = read_frame_header flow in
  skip_frame_payload flow len;
  if ty = 0x01 then (
    write_string flow (headers_frame ~end_headers:true ~stream_id:sid hpack_indexed_status_200);
    for _i = 1 to count do
      write_string flow (data_frame ~end_stream:false ~stream_id:sid "");
      if delay_sec > 0.0 then Eio.Time.sleep (Eio.Stdenv.clock env) delay_sec
    done;
    write_string flow (data_frame ~end_stream:true ~stream_id:sid ""))

let serve_window_overflow ~env flow =
  let len, ty, _flags, sid = read_frame_header flow in
  skip_frame_payload flow len;
  if ty = 0x01 then (
    write_string flow (headers_frame ~end_headers:true ~stream_id:sid hpack_indexed_status_200);
    write_string flow (window_update_frame ~stream_id:sid 0x7FFFFFFF);
    write_string flow (window_update_frame ~stream_id:0 0x7FFFFFFF))

let serve_goaway_churn ~env ~count flow =
  let len, ty, _flags, sid = read_frame_header flow in
  skip_frame_payload flow len;
  for _i = 1 to count do
    write_string flow (goaway_frame ~last_stream_id:sid ~error_code:0 ());
    Eio.Time.sleep (Eio.Stdenv.clock env) 0.1
  done

let generate_gzip_bomb ~path ~expanded_bytes =
  let zeros = String.make (min expanded_bytes (1024 * 1024)) '\x00' in
  let zeros_path = path ^ ".zeros" in
  let oc = open_out_bin zeros_path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       let written = ref 0 in
       while !written < expanded_bytes do
         let chunk_size = min (expanded_bytes - !written) (String.length zeros) in
         output_substring oc zeros 0 chunk_size;
         written := !written + chunk_size
       done);
  ignore (Sys.command (Printf.sprintf "gzip -f %s && mv %s.gz %s" (Filename.quote zeros_path) (Filename.quote zeros_path) (Filename.quote path)))
