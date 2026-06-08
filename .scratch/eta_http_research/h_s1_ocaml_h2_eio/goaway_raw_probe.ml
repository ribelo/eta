open H2

let chr n = Char.chr n

let frame_header ~length ~frame_type ~flags ~stream_id =
  String.init 9 @@ fun i ->
  match i with
  | 0 -> chr ((length lsr 16) land 0xff)
  | 1 -> chr ((length lsr 8) land 0xff)
  | 2 -> chr (length land 0xff)
  | 3 -> chr frame_type
  | 4 -> chr flags
  | 5 -> chr ((stream_id lsr 24) land 0x7f)
  | 6 -> chr ((stream_id lsr 16) land 0xff)
  | 7 -> chr ((stream_id lsr 8) land 0xff)
  | 8 -> chr (stream_id land 0xff)
  | _ -> assert false

let uint32 n =
  String.init 4 @@ fun i ->
  match i with
  | 0 -> chr ((n lsr 24) land 0xff)
  | 1 -> chr ((n lsr 16) land 0xff)
  | 2 -> chr ((n lsr 8) land 0xff)
  | 3 -> chr (n land 0xff)
  | _ -> assert false

let settings_frame = frame_header ~length:0 ~frame_type:0x4 ~flags:0 ~stream_id:0

let goaway_no_error ~last_stream_id =
  frame_header ~length:8 ~frame_type:0x7 ~flags:0 ~stream_id:0
  ^ uint32 last_stream_id
  ^ uint32 0

let feed client bytes =
  match Client_connection.next_read_operation client with
  | `Read ->
    let bs = Bigstringaf.of_string ~off:0 ~len:(String.length bytes) bytes in
    ignore (Client_connection.read client bs ~off:0 ~len:(String.length bytes))
  | `Close -> failwith "client reader closed before raw frame feed"

let drain_client_writes client =
  let rec loop writes =
    match Client_connection.next_write_operation client with
    | `Write iovecs ->
      let len =
        List.fold_left (fun total { IOVec.len; _ } -> total + len) 0 iovecs
      in
      Client_connection.report_write_result client (`Ok len);
      loop (writes + 1)
    | `Yield -> writes
    | `Close _ -> writes
  in
  loop 0

let pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
    Format.asprintf "protocol_error:%a:%s" Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let issue_request client target stream_errors =
  let request =
    Request.create
      ~scheme:"https"
      ~headers:(Headers.of_list [ ":authority", "local.test" ])
      `GET
      target
  in
  let body =
    Client_connection.request
      client
      request
      ~error_handler:(fun err ->
        stream_errors := (target, pp_client_error err) :: !stream_errors)
      ~response_handler:(fun _response _body ->
        failwith "raw GOAWAY probe should not receive a response")
  in
  Body.Writer.close body

let require label cond =
  if not cond then failwith ("require failed: " ^ label)

let () =
  let connection_errors = ref [] in
  let stream_errors = ref [] in
  let client =
    Client_connection.create
      ~error_handler:(fun err ->
        connection_errors := pp_client_error err :: !connection_errors)
      ()
  in
  issue_request client "/before-goaway-1" stream_errors;
  issue_request client "/after-cutoff-stream-3" stream_errors;
  let writes_before_goaway = drain_client_writes client in
  feed client settings_frame;
  feed client (goaway_no_error ~last_stream_id:1);
  let closed_before_flush = Client_connection.is_closed client in
  let writes_after_goaway = drain_client_writes client in
  let closed_after_flush = Client_connection.is_closed client in
  require "NO_ERROR GOAWAY should not be reported as connection error" (!connection_errors = []);
  require "GOAWAY does not notify streams above last_stream_id" (!stream_errors = []);
  Printf.printf
    "h_s1_goaway_raw last_stream_id=1 stream_errors=%d connection_errors=%d closed_before_flush=%b closed_after_flush=%b writes_before=%d writes_after=%d\n%!"
    (List.length !stream_errors)
    (List.length !connection_errors)
    closed_before_flush
    closed_after_flush
    writes_before_goaway
    writes_after_goaway
