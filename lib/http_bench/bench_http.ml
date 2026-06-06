let response_bytes =
  Bytes.of_string
    "HTTP/1.1 200 OK\r\ncontent-length: 11\r\ncontent-type: text/plain\r\n\r\nhello world"

let request_body = [ Bytes.of_string "hello"; Bytes.of_string " "; Bytes.of_string "world" ]

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let ws_text_payload = Bytes.of_string "{\"type\":\"response.create\"}"
let ws_binary_payload = Bytes.make 960 '\000'
let ws_mask = Bytes.of_string "\001\002\003\004"

let ws_unmasked_text_frame =
  Eta_http.Ws.Codec.encode
    { fin = true; opcode = Text; payload = ws_text_payload }

let ws_masked_binary_frame =
  Eta_http.Ws.Codec.encode ~mask:ws_mask
    { fin = true; opcode = Binary; payload = ws_binary_payload }

let ws_codec_encode_text () =
  ignore
    (Eta_http.Ws.Codec.encode
       { fin = true; opcode = Text; payload = ws_text_payload })

let ws_codec_decode_text () =
  match Eta_http.Ws.Codec.decode ws_unmasked_text_frame with
  | Ok ({ opcode = Text; _ }, _) -> ()
  | Ok _ -> failwith "unexpected WebSocket text decode"
  | Error error -> failwith (Eta_http.Ws.Codec.parse_error_to_string error)

let ws_codec_encode_masked_binary () =
  ignore
    (Eta_http.Ws.Codec.encode ~mask:ws_mask
       { fin = true; opcode = Binary; payload = ws_binary_payload })

let ws_codec_decode_masked_binary () =
  match Eta_http.Ws.Codec.decode ~masked:true ws_masked_binary_frame with
  | Ok ({ opcode = Binary; _ }, _) -> ()
  | Ok _ -> failwith "unexpected WebSocket binary decode"
  | Error error -> failwith (Eta_http.Ws.Codec.parse_error_to_string error)

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected TCP listener"

let has_suffix suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  value_len >= suffix_len
  && String.equal suffix
       (String.sub value (value_len - suffix_len) suffix_len)

let read_http_head flow =
  let scratch = Cstruct.create 1 in
  let buffer = Buffer.create 512 in
  let rec loop () =
    let read = Eio.Flow.single_read flow scratch in
    if read = 0 then raise End_of_file;
    Buffer.add_char buffer (Cstruct.get_char scratch 0);
    let contents = Buffer.contents buffer in
    if has_suffix "\r\n\r\n" contents then contents else loop ()
  in
  loop ()

let header_value name raw =
  let expected = String.lowercase_ascii name in
  raw |> String.split_on_char '\n'
  |> List.find_map (fun line ->
         let line =
           let len = String.length line in
           if len > 0 && Char.equal line.[len - 1] '\r' then
             String.sub line 0 (len - 1)
           else line
         in
         match String.index_opt line ':' with
         | None -> None
         | Some index ->
             let actual =
               String.sub line 0 index |> String.trim |> String.lowercase_ascii
             in
             if String.equal actual expected then
               Some
                 (String.sub line (index + 1) (String.length line - index - 1)
                  |> String.trim)
             else None)

let bytes_concat chunks =
  let len = List.fold_left (fun acc chunk -> acc + Bytes.length chunk) 0 chunks in
  let out = Bytes.create len in
  let off = ref 0 in
  List.iter
    (fun chunk ->
      Bytes.blit chunk 0 out !off (Bytes.length chunk);
      off := !off + Bytes.length chunk)
    chunks;
  out

let read_exact flow len =
  let out = Cstruct.create len in
  let rec loop off =
    if off = len then Cstruct.to_bytes out
    else
      let read = Eio.Flow.single_read flow (Cstruct.sub out off (len - off)) in
      if read = 0 then raise End_of_file else loop (off + read)
  in
  loop 0

let ws_payload_len header ext =
  match Char.code (Bytes.get header 1) land 0x7f with
  | value when value < 126 -> value
  | 126 ->
      (Char.code (Bytes.get ext 0) lsl 8) lor Char.code (Bytes.get ext 1)
  | _ ->
      let acc = ref 0L in
      for index = 0 to 7 do
        acc :=
          Int64.logor
            (Int64.shift_left !acc 8)
            (Int64.of_int (Char.code (Bytes.get ext index)))
      done;
      Int64.to_int !acc

let read_ws_frame ~masked flow =
  let header = read_exact flow 2 in
  let len_code = Char.code (Bytes.get header 1) land 0x7f in
  let ext_len = if len_code < 126 then 0 else if len_code = 126 then 2 else 8 in
  let ext = read_exact flow ext_len in
  let mask_len = if Char.code (Bytes.get header 1) land 0x80 = 0 then 0 else 4 in
  let mask = read_exact flow mask_len in
  let payload = read_exact flow (ws_payload_len header ext) in
  match Eta_http.Ws.Codec.decode ~masked (bytes_concat [ header; ext; mask; payload ]) with
  | Ok (frame, _) -> frame
  | Error error -> failwith (Eta_http.Ws.Codec.parse_error_to_string error)

let write_ws_switching_response flow key =
  Eio.Flow.copy_string
    ("HTTP/1.1 101 Switching Protocols\r\n"
    ^ "Upgrade: websocket\r\n"
    ^ "Connection: Upgrade\r\n"
    ^ "Sec-WebSocket-Accept: "
    ^ Eta_http.Ws.Codec.accept_key key
    ^ "\r\n\r\n")
    flow

let run_ws_echo_server ~messages flow =
  let head = read_http_head flow in
  let key =
    match header_value "Sec-WebSocket-Key" head with
    | Some key -> key
    | None -> failwith "missing Sec-WebSocket-Key"
  in
  write_ws_switching_response flow key;
  for _ = 1 to messages do
    let frame = read_ws_frame ~masked:true flow in
    let opcode = frame.Eta_http.Ws.Codec.opcode in
    match opcode with
    | Text | Binary ->
        Eta_http.Ws.Codec.encode
          { fin = true; opcode; payload = frame.payload }
        |> Bytes.to_string |> fun encoded -> Eio.Flow.copy_string encoded flow
    | Close -> ()
    | Continuation | Ping | Pong -> failwith "unexpected WebSocket bench frame"
  done;
  Eta_http.Ws.Codec.encode
    { fin = true; opcode = Close; payload = Bytes.of_string "\003\232" }
  |> Bytes.to_string |> fun encoded -> Eio.Flow.copy_string encoded flow;
  try Eio.Flow.shutdown flow `Send with _ -> ()

let pp_ws_error fmt = function
  | `Connect message -> Format.fprintf fmt "connect %s" message
  | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
  | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
  | `Protocol message -> Format.fprintf fmt "protocol %s" message
  | `Timeout -> Format.pp_print_string fmt "timeout"

let run_ws_effect rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith (Format.asprintf "%a" (Eta.Cause.pp pp_ws_error) cause)

let rec ws_send_loop conn i n =
  if i = n then Eta.Effect.unit
  else
    Eta_http.Ws.Client.send_text conn "ping"
    |> Eta.Effect.bind (fun () -> ws_send_loop conn (i + 1) n)

let ws_loopback_echo messages =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      run_ws_echo_server ~messages flow);
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let url = Printf.sprintf "ws://127.0.0.1:%d/realtime" port in
  let program =
    Eta_http.Ws.Client.connect ~sw ~net url
    |> Eta.Effect.bind (fun conn ->
           Eta.Effect.par
             (ws_send_loop conn 0 messages)
             (Eta_http.Ws.Client.incoming conn
             |> Eta_stream.Stream.take messages
             |> Eta_stream.run_collect)
           |> Eta.Effect.map (fun (_sent, received) ->
                  if List.length received <> messages then
                    failwith "WebSocket loopback dropped messages"))
  in
  run_ws_effect rt program

let parse_response () =
  match Eta_http.H1.Parse.parse response_bytes ~len:(Bytes.length response_bytes) with
  | Ok response ->
      ignore (Eta_http.H1.Parse.headers_to_list response_bytes response.headers);
      ignore (Eta_http.H1.Parse.body_to_bytes response_bytes response)
  | Error err -> failwith (Eta_http.H1.Parse.parse_error_to_string err)

let parse_response_raw () =
  let headers = Eta_http.H1.Parse.create_raw_headers 16 in
  let response = Eta_http.H1.Parse.create_raw_response () in
  let code =
    Eta_http.H1.Parse.parse_raw response_bytes ~len:(Bytes.length response_bytes)
      ~max_header_bytes:4096 ~headers response
  in
  if code <> Eta_http.H1.Parse.raw_ok then failwith "raw parse failed";
  ignore (Eta_http.H1.Parse.raw_headers_to_list response_bytes headers response);
  ignore (Eta_http.H1.Parse.raw_body_len response)

let write_request () =
  let body = Eta_http.H1.Write.Fixed request_body in
  let url = Eta_http.Core.Url.of_string "https://example.com/submit" in
  ignore
    (Eta_http.H1.Write.to_string ~method_:"POST" ~url
       ~headers:(Eta_http.Core.Header.unsafe_of_list [ ("host", "example.com") ])
       ~body)

let url_request () =
  let request =
    Eta_http.Request.make ~body:(Fixed request_body) "POST"
      "https://example.com:443/path?q=1#fragment"
  in
  ignore (Eta_http.Request.url request);
  ignore (Eta_http.Request.body_chunks request)

let h2_security () =
  ignore (Eta_http.H2.Security.validate_headers [ ("content-type", "text/plain") ])

let projection_error =
  Eta_http.Error.make ~protocol:H2 ~method_:"GET"
    ~uri:"https://api.example.test/v1/models?token=secret#frag"
    (HTTP_status
       {
         status = 503;
         headers =
           [
             ("authorization", "Bearer secret");
             ("Cookie", "sid=secret-cookie");
             ("Set-Cookie", "sid=secret-cookie");
             ("X-API-Key", "secret-key");
             ("Content-Type", "text/plain");
           ];
       })

let error_projection_json () =
  ignore (Eta_http.Error_projection.to_json projection_error)

let workloads =
  let item name run =
    { Bench_lib.name = "http." ^ name; run; samples = None }
  in
  [
    item "h1.parse.response.100k" (fun () -> repeat 100_000 parse_response);
    item "h1.parse_raw.response.100k" (fun () -> repeat 100_000 parse_response_raw);
    item "h1.write.request.100k" (fun () -> repeat 100_000 write_request);
    item "request.url_body.100k" (fun () -> repeat 100_000 url_request);
    item "error.projection_json.100k" (fun () ->
        repeat 100_000 error_projection_json);
    item "h2.security.headers.10k" (fun () -> repeat 10_000 h2_security);
    item "ws.codec.encode.text.100k" (fun () -> repeat 100_000 ws_codec_encode_text);
    item "ws.codec.decode.text.100k" (fun () -> repeat 100_000 ws_codec_decode_text);
    item "ws.codec.encode.masked_binary_960b.100k" (fun () ->
        repeat 100_000 ws_codec_encode_masked_binary);
    item "ws.codec.decode.masked_binary_960b.100k" (fun () ->
        repeat 100_000 ws_codec_decode_masked_binary);
    item "ws.loopback.echo_text.1k" (fun () -> ws_loopback_echo 1_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
