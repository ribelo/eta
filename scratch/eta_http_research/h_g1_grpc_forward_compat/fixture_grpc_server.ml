let iovecs_to_string iovecs =
  iovecs
  |> Eta_http.H2.Writer.cstructs_of_iovecs
  |> List.map Cstruct.to_string
  |> String.concat ""

let feed_client client data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = H2.Client_connection.read client buffer ~off:0 ~len in
      if consumed <= 0 then failwith "client consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let feed_server server data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = H2.Server_connection.read server buffer ~off:0 ~len in
      if consumed <= 0 then failwith "server consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let drain_client_to_server client server =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      let data = iovecs_to_string iovecs in
      H2.Client_connection.report_write_result client (`Ok (String.length data));
      feed_server server data;
      true
  | `Yield -> false
  | `Close _ ->
      H2.Client_connection.report_write_result client `Closed;
      false

let drain_server_to_client server client =
  match H2.Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = iovecs_to_string iovecs in
      H2.Server_connection.report_write_result server (`Ok (String.length data));
      feed_client client data;
      true
  | `Yield -> false
  | `Close _ ->
      H2.Server_connection.report_write_result server `Closed;
      false

let pump_pair ?(limit = 10_000) client server =
  let rec loop remaining progress =
    if remaining <= 0 then failwith "h2 pump did not quiesce"
    else
      let client_progress = drain_client_to_server client server in
      let server_progress = drain_server_to_client server client in
      if client_progress || server_progress then loop (remaining - 1) true
      else progress
  in
  loop limit false

let grpc_message_bytes payload =
  let len = String.length payload in
  String.init 5 (function
    | 0 -> '\000'
    | 1 -> Char.chr ((len lsr 24) land 0xff)
    | 2 -> Char.chr ((len lsr 16) land 0xff)
    | 3 -> Char.chr ((len lsr 8) land 0xff)
    | 4 -> Char.chr (len land 0xff)
    | _ -> assert false)
  ^ payload

let create ?(payload = "hello") ~grpc_status ~grpc_message () =
  H2.Server_connection.create (fun reqd ->
      let response_body =
        H2.Reqd.respond_with_streaming reqd
          (H2.Response.create
             ~headers:(H2.Headers.of_list [ "content-type", "application/grpc+proto" ])
             `OK)
      in
      H2.Body.Writer.write_string response_body (grpc_message_bytes payload);
      H2.Reqd.schedule_trailers reqd
        (H2.Headers.of_list
           [ "grpc-status", grpc_status; "grpc-message", grpc_message ]);
      H2.Body.Writer.close response_body)
