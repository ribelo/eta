open H2

type client_result =
  { mutable status : int option
  ; mutable body : string
  ; mutable eof : bool
  ; mutable client_errors : string list
  ; mutable stream_errors : string list
  ; mutable server_seen : string list
  }

let pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
    Format.asprintf "protocol_error:%a:%s" Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let pp_server_error = function
  | `Bad_request -> "bad_request"
  | `Internal_server_error -> "internal_server_error"
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let string_of_iovec { IOVec.buffer; off; len } =
  Bigstringaf.substring buffer ~off ~len

let concat_iovecs iovecs =
  let chunks = List.map string_of_iovec iovecs in
  String.concat "" chunks

let read_string read conn data =
  let len = String.length data in
  if len > 0 then
    let bs = Bigstringaf.of_string ~off:0 ~len data in
    ignore (read conn bs ~off:0 ~len : int)

let rec drain_client_output client server =
  match Client_connection.next_write_operation client with
  | `Write iovecs ->
    let data = concat_iovecs iovecs in
    let len = String.length data in
    Client_connection.report_write_result client (`Ok len);
    read_string Server_connection.read server data;
    true || drain_client_output client server
  | `Yield ->
    false
  | `Close _ ->
    Client_connection.report_write_result client `Closed;
    false

let rec drain_server_output server client =
  match Server_connection.next_write_operation server with
  | `Write iovecs ->
    let data = concat_iovecs iovecs in
    let len = String.length data in
    Server_connection.report_write_result server (`Ok len);
    read_string Client_connection.read client data;
    true || drain_server_output server client
  | `Yield ->
    false
  | `Close _ ->
    Server_connection.report_write_result server `Closed;
    false

let rec pump ?(limit = 1000) client server =
  if limit <= 0 then failwith "pump did not quiesce";
  let c = drain_client_output client server in
  let s = drain_server_output server client in
  if c || s then pump ~limit:(limit - 1) client server

let schedule_body_read result body =
  let rec loop () =
    if Body.Reader.is_closed body then result.eof <- true
    else
      Body.Reader.schedule_read
        body
        ~on_eof:(fun () -> result.eof <- true)
        ~on_read:(fun bs ~off ~len ->
          result.body <- result.body ^ Bigstringaf.substring bs ~off ~len;
          loop ())
  in
  loop ()

let run_single_get () =
  let result =
    { status = None
    ; body = ""
    ; eof = false
    ; client_errors = []
    ; stream_errors = []
    ; server_seen = []
    }
  in
  let server =
    Server_connection.create
      ~error_handler:(fun ?request:_ err respond ->
        result.stream_errors <- pp_server_error err :: result.stream_errors;
        let body = respond (Headers.of_list [ "content-type", "text/plain" ]) in
        Body.Writer.write_string body "server-error";
        Body.Writer.close body)
      (fun reqd ->
        let request = Reqd.request reqd in
        result.server_seen <- request.target :: result.server_seen;
        Reqd.respond_with_string
          reqd
          (Response.create
             ~headers:(Headers.of_list [ "content-type", "text/plain" ])
             `OK)
          "hello-h2")
  in
  let client =
    Client_connection.create
      ~error_handler:(fun err ->
        result.client_errors <- pp_client_error err :: result.client_errors)
      ()
  in
  let request =
    Request.create
      ~scheme:"http"
      ~headers:(Headers.of_list [ ":authority", "local.test" ])
      `GET
      "/single"
  in
  let request_body =
    Client_connection.request
      client
      request
      ~error_handler:(fun err ->
        result.stream_errors <- pp_client_error err :: result.stream_errors)
      ~response_handler:(fun response body ->
        result.status <- Some (Status.to_code response.status);
        schedule_body_read result body)
  in
  Body.Writer.close request_body;
  pump client server;
  result

let require label cond =
  if not cond then failwith ("require failed: " ^ label)

let () =
  let result = run_single_get () in
  require "status 200" (result.status = Some 200);
  require "body" (String.equal result.body "hello-h2");
  require "eof" result.eof;
  require "server target" (result.server_seen = [ "/single" ]);
  require "no client errors" (result.client_errors = []);
  require "no stream errors" (result.stream_errors = []);
  Printf.printf
    "h_s1_p1_single_get status=%d body=%S server_seen=%s\n%!"
    200
    result.body
    (String.concat "," result.server_seen)
