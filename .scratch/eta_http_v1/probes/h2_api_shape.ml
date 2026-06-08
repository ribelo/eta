open H2

type result = {
  mutable status : int option;
  body : Buffer.t;
  mutable eof : bool;
  mutable client_errors : int;
  mutable stream_errors : int;
  mutable server_targets : string list;
}

let result () =
  {
    status = None;
    body = Buffer.create 32;
    eof = false;
    client_errors = 0;
    stream_errors = 0;
    server_targets = [];
  }

let string_of_iovec { IOVec.buffer; off; len } =
  Bigstringaf.substring buffer ~off ~len

let concat_iovecs iovecs =
  iovecs |> List.map string_of_iovec |> String.concat ""

let feed read conn data =
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
  let rec loop () =
    if Body.Reader.is_closed body then result.eof <- true
    else
      Body.Reader.schedule_read body
        ~on_eof:(fun () -> result.eof <- true)
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string result.body (Bigstringaf.substring bs ~off ~len);
          loop ())
  in
  loop ()

let run_get () =
  let result = result () in
  let server =
    Server_connection.create
      ~error_handler:(fun ?request:_ _ respond ->
        result.stream_errors <- result.stream_errors + 1;
        let body = respond (Headers.of_list [ "content-type", "text/plain" ]) in
        Body.Writer.write_string body "server-error";
        Body.Writer.close body)
      (fun reqd ->
        let request = Reqd.request reqd in
        result.server_targets <- request.target :: result.server_targets;
        Reqd.respond_with_string reqd
          (Response.create
             ~headers:(Headers.of_list [ "content-type", "text/plain" ])
             `OK)
          "hello-h2")
  in
  let client =
    Client_connection.create
      ~error_handler:(fun _ -> result.client_errors <- result.client_errors + 1)
      ()
  in
  let request =
    Request.create ~scheme:"https"
      ~headers:(Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/r7"
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

let require label condition =
  if not condition then failwith ("require failed: " ^ label)

let () =
  let result = run_get () in
  require "status 200" (result.status = Some 200);
  require "body" (String.equal (Buffer.contents result.body) "hello-h2");
  require "eof" result.eof;
  require "server target" (result.server_targets = [ "/r7" ]);
  require "no client errors" (result.client_errors = 0);
  require "no stream errors" (result.stream_errors = 0);
  Printf.printf
    "eta_http_r7_h2_api_shape verdict=PASS status=200 body=%S target=/r7\n%!"
    (Buffer.contents result.body)
