open H2

type push_result = {
  mutable status : int option;
  mutable body : string;
  mutable saw_push_disabled : bool;
  mutable accepted_push : bool;
  mutable client_errors : int;
  mutable stream_errors : int;
}

let push_result () =
  {
    status = None;
    body = "";
    saw_push_disabled = false;
    accepted_push = false;
    client_errors = 0;
    stream_errors = 0;
  }

let chr n = Char.chr (n land 0xff)

let set_u31 bytes offset value =
  let value = Int32.logand value 0x7fffffffl |> Int32.to_int in
  Bytes.set bytes offset (chr (value lsr 24));
  Bytes.set bytes (offset + 1) (chr (value lsr 16));
  Bytes.set bytes (offset + 2) (chr (value lsr 8));
  Bytes.set bytes (offset + 3) (chr value)

let frame frame_type flags stream_id payload =
  let payload_len = String.length payload in
  let bytes = Bytes.create (9 + payload_len) in
  Bytes.set bytes 0 (chr (payload_len lsr 16));
  Bytes.set bytes 1 (chr (payload_len lsr 8));
  Bytes.set bytes 2 (chr payload_len);
  Bytes.set bytes 3 (chr frame_type);
  Bytes.set bytes 4 (chr flags);
  set_u31 bytes 5 stream_id;
  Bytes.blit_string payload 0 bytes 9 payload_len;
  Bytes.unsafe_to_string bytes

let settings_frame () = frame 0x4 0x0 0l ""

let connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let priority_frame ~stream_id ~dependency =
  let payload = Bytes.create 5 in
  set_u31 payload 0 dependency;
  Bytes.set payload 4 (chr 15);
  frame 0x2 0x0 stream_id (Bytes.unsafe_to_string payload)

let push_promise_frame ~stream_id ~promised_id =
  let payload = Bytes.create 4 in
  set_u31 payload 0 promised_id;
  frame 0x5 0x4 stream_id (Bytes.unsafe_to_string payload)

let string_of_iovec { IOVec.buffer; off; len } =
  Bigstringaf.substring buffer ~off ~len

let concat_iovecs iovecs = iovecs |> List.map string_of_iovec |> String.concat ""

let feed read conn data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let bs = Bigstringaf.of_string ~off ~len data in
      let consumed = read conn bs ~off:0 ~len in
      if consumed <= 0 then failwith "h2 peer consumed no bytes";
      loop (off + consumed))
  in
  loop 0

let rec drain_client_output client server =
  match Client_connection.next_write_operation client with
  | `Write iovecs ->
      let data = concat_iovecs iovecs in
      let len = String.length data in
      Client_connection.report_write_result client (`Ok len);
      feed Server_connection.read server data;
      ignore (drain_client_output client server);
      true
  | `Yield -> false
  | `Close _ ->
      Client_connection.report_write_result client `Closed;
      false

let rec drain_server_output server client =
  match Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = concat_iovecs iovecs in
      let len = String.length data in
      Server_connection.report_write_result server (`Ok len);
      feed Client_connection.read client data;
      ignore (drain_server_output server client);
      true
  | `Yield -> false
  | `Close _ ->
      Server_connection.report_write_result server `Closed;
      false

let rec pump ?(limit = 1000) client server =
  if limit <= 0 then failwith "h2 pump did not quiesce";
  let client_wrote = drain_client_output client server in
  let server_wrote = drain_server_output server client in
  if client_wrote || server_wrote then pump ~limit:(limit - 1) client server

let schedule_response_body result body =
  Body.Reader.schedule_read body
    ~on_eof:(fun () -> ())
    ~on_read:(fun bs ~off ~len ->
      result.body <- Bigstringaf.substring bs ~off ~len)

let run_push_disabled_by_settings () =
  let result = push_result () in
  let server =
    Server_connection.create
      ~error_handler:(fun ?request:_ _ respond ->
        result.stream_errors <- result.stream_errors + 1;
        let body = respond Headers.empty in
        Body.Writer.close body)
      (fun reqd ->
        let pushed_request =
          Request.create ~scheme:"https"
            ~headers:(Headers.of_list [ ":authority", "api.example.test" ])
            `GET "/pushed"
        in
        (match Reqd.push reqd pushed_request with
        | Error `Push_disabled -> result.saw_push_disabled <- true
        | Error (`Stream_cant_push | `Stream_ids_exhausted) ->
            result.stream_errors <- result.stream_errors + 1
        | Ok pushed ->
            result.accepted_push <- true;
            Reqd.respond_with_string pushed (Response.create `OK) "pushed");
        Reqd.respond_with_string reqd (Response.create `OK) "main")
  in
  let client =
    Client_connection.create
      ~error_handler:(fun _ -> result.client_errors <- result.client_errors + 1)
      ()
  in
  let request =
    Request.create ~scheme:"https"
      ~headers:(Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/main"
  in
  let request_body =
    Client_connection.request client request
      ~error_handler:(fun _ -> result.stream_errors <- result.stream_errors + 1)
      ~response_handler:(fun response body ->
        result.status <- Some (Status.to_code response.status);
        schedule_response_body result body)
  in
  Body.Writer.close request_body;
  pump client server;
  result

let forced_push_promise_error () =
  let errors = ref [] in
  let client =
    Client_connection.create
      ~error_handler:(fun error -> errors := error :: !errors)
      ()
  in
  feed Client_connection.read client (settings_frame ());
  feed Client_connection.read client
    (push_promise_frame ~stream_id:1l ~promised_id:2l);
  match !errors with
  | [ `Protocol_error (Error_code.ProtocolError, reason) ] ->
      String.equal reason "Push is disabled for this connection"
  | _ -> false

let rec drain_server_bytes server acc =
  match Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = concat_iovecs iovecs in
      Server_connection.report_write_result server (`Ok (String.length data));
      drain_server_bytes server (data :: acc)
  | `Yield -> String.concat "" (List.rev acc)
  | `Close _ ->
      Server_connection.report_write_result server `Closed;
      String.concat "" (List.rev acc)

let contains_frame_type frame_type data =
  let rec loop offset =
    if offset + 9 > String.length data then false
    else
      let payload_len =
        (Char.code data.[offset] lsl 16)
        lor (Char.code data.[offset + 1] lsl 8)
        lor Char.code data.[offset + 2]
      in
      Char.code data.[offset + 3] = frame_type
      || loop (offset + 9 + payload_len)
  in
  loop 0

let server_priority_tolerated () =
  let server = Server_connection.create (fun _ -> ()) in
  feed Server_connection.read server
    (connection_preface ^ settings_frame ()
    ^ priority_frame ~stream_id:1l ~dependency:0l);
  let output = drain_server_bytes server [] in
  (not (contains_frame_type 0x7 output)) && not (Server_connection.is_closed server)

let client_priority_tolerated () =
  let errors = ref [] in
  let client =
    Client_connection.create
      ~error_handler:(fun error -> errors := error :: !errors)
      ()
  in
  feed Client_connection.read client (settings_frame ());
  feed Client_connection.read client (priority_frame ~stream_id:2l ~dependency:0l);
  !errors = [] && not (Client_connection.is_closed client)

let require label condition =
  if not condition then failwith ("require failed: " ^ label)

let () =
  let push = run_push_disabled_by_settings () in
  require "main response status" (push.status = Some 200);
  require "main response body" (String.equal push.body "main");
  require "server saw push disabled" push.saw_push_disabled;
  require "server did not accept push" (not push.accepted_push);
  require "no push path client errors" (push.client_errors = 0);
  require "no push path stream errors" (push.stream_errors = 0);
  require "forced PUSH_PROMISE protocol error" (forced_push_promise_error ());
  require "server PRIORITY tolerance" (server_priority_tolerated ());
  require "client PRIORITY tolerance" (client_priority_tolerated ());
  Printf.printf
    "eta_http_r8_push_priority verdict=PASS push_disabled=true \
     forced_push_protocol_error=true priority_tolerated=true\n%!"
