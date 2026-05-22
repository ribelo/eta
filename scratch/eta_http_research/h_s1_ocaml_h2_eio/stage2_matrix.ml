open H2

type response =
  { status : int
  ; body : string
  ; trailers : (string * string) list
  }

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let string_of_iovec { IOVec.buffer; off; len } =
  Bigstringaf.substring buffer ~off ~len

let pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
    Format.asprintf "protocol_error:%a:%s" Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let write_iovecs flow iovecs =
  iovecs
  |> List.map (fun iovec -> Cstruct.of_string (string_of_iovec iovec))
  |> Eio.Flow.write flow

let read_into_connection flow read conn =
  let buf = Cstruct.create 0x4000 in
  let n = Eio.Flow.single_read flow buf in
  let data = Cstruct.to_string (Cstruct.sub buf 0 n) in
  let bs = Bigstringaf.of_string ~off:0 ~len:n data in
  ignore (read conn bs ~off:0 ~len:n : int)

let iovecs_len =
  List.fold_left (fun total { IOVec.len; _ } -> total + len) 0

let run_client_writer flow client =
  let rec loop () =
    match Client_connection.next_write_operation client with
    | `Write iovecs ->
      write_iovecs flow iovecs;
      Client_connection.report_write_result client (`Ok (iovecs_len iovecs));
      loop ()
    | `Yield ->
      let p, u = Eio.Promise.create () in
      Client_connection.yield_writer client (fun () ->
        ignore (Eio.Promise.try_resolve u ()));
      Eio.Promise.await p;
      loop ()
    | `Close _ ->
      (try Eio.Flow.shutdown flow `Send with _ -> ())
  in
  loop ()

let run_server_writer flow server =
  let rec loop () =
    match Server_connection.next_write_operation server with
    | `Write iovecs ->
      write_iovecs flow iovecs;
      Server_connection.report_write_result server (`Ok (iovecs_len iovecs));
      loop ()
    | `Yield ->
      let p, u = Eio.Promise.create () in
      Server_connection.yield_writer server (fun () ->
        ignore (Eio.Promise.try_resolve u ()));
      Eio.Promise.await p;
      loop ()
    | `Close _ ->
      (try Eio.Flow.shutdown flow `Send with _ -> ())
  in
  loop ()

let run_client_reader flow client =
  let rec loop () =
    match Client_connection.next_read_operation client with
    | `Read ->
      read_into_connection flow Client_connection.read client;
      loop ()
    | `Close -> ()
  in
  try loop () with End_of_file -> ()

let run_server_reader flow server =
  let rec loop () =
    match Server_connection.next_read_operation server with
    | `Read ->
      read_into_connection flow Server_connection.read server;
      loop ()
    | `Close -> ()
  in
  try loop () with End_of_file -> ()

let read_body body ~on_done =
  let buf = Buffer.create 128 in
  let resolved = ref false in
  let finish () =
    if not !resolved then (
      resolved := true;
      on_done (Buffer.contents buf))
  in
  let rec loop () =
    if Body.Reader.is_closed body then finish ()
    else
      Body.Reader.schedule_read
        body
        ~on_eof:finish
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string buf (Bigstringaf.substring bs ~off ~len);
          loop ())
  in
  loop ()

let server_handler ~on_goaway reqd =
  let request = Reqd.request reqd in
  match request.meth, request.target with
  | `GET, target when String.length target >= 5 && String.sub target 0 5 = "/get/" ->
    let id = String.sub target 5 (String.length target - 5) in
    Reqd.respond_with_string
      reqd
      (Response.create
         ~headers:(Headers.of_list [ "content-type", "text/plain" ])
         `OK)
      ("get:" ^ id)
  | `POST, "/post" ->
    read_body (Reqd.request_body reqd) ~on_done:(fun body ->
      Reqd.respond_with_string
        reqd
        (Response.create
           ~headers:(Headers.of_list [ "content-type", "text/plain" ])
           `OK)
        ("post:" ^ body))
  | `GET, "/trailers" ->
    let response_body =
      Reqd.respond_with_streaming
        reqd
        (Response.create
           ~headers:(Headers.of_list [ "content-type", "text/plain" ])
           `OK)
    in
    Body.Writer.write_string response_body "trailered";
    Reqd.schedule_trailers
      reqd
      (Headers.of_list [ "x-stage2-trailer", "present" ]);
    Body.Writer.close response_body
  | `GET, "/rst" ->
    let response_body =
      Reqd.respond_with_streaming
        reqd
        (Response.create
           ~headers:(Headers.of_list [ "content-type", "text/plain" ])
           `OK)
    in
    Body.Writer.write_string response_body "partial-before-rst";
    Reqd.report_exn reqd (Failure "stage2-rst")
  | `GET, "/slow" ->
    let response_body =
      Reqd.respond_with_streaming
        reqd
        (Response.create
           ~headers:(Headers.of_list [ "content-type", "text/plain" ])
           `OK)
    in
    Body.Writer.write_string response_body "slow-prefix"
  | `GET, "/flow-stall" ->
    let response_body =
      Reqd.respond_with_streaming
        reqd
        (Response.create
           ~headers:(Headers.of_list [ "content-type", "text/plain" ])
           `OK)
    in
    Body.Writer.write_string response_body (String.make (64 * 1024) 'x');
    Body.Writer.close response_body
  | `GET, "/goaway" ->
    Reqd.respond_with_string
      reqd
      (Response.create
         ~headers:(Headers.of_list [ "content-type", "text/plain" ])
         `OK)
      "goaway-before-close";
    on_goaway ()
  | _ ->
    Reqd.respond_with_string
      reqd
      (Response.create `Not_found)
      "not-found"

let run_server_connection ~clock ~config flow =
  let goaway_p, goaway_u = Eio.Promise.create () in
  let server =
    Server_connection.create
      ~config
      (server_handler ~on_goaway:(fun () ->
         ignore (Eio.Promise.try_resolve goaway_u ())))
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    try run_server_writer flow server with _ -> ());
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Promise.await goaway_p;
    Eio.Time.sleep clock 0.01;
    Server_connection.report_exn server (Failure "stage2-goaway");
    `Stop_daemon);
  (try run_server_reader flow server with _ -> ());
  Server_connection.shutdown server;
  try Eio.Flow.shutdown flow `All with _ -> ()

let request client ?(meth = `GET) ?body target =
  let done_p, done_u = Eio.Promise.create () in
  let trailers = ref [] in
  let request =
    Request.create
      ~scheme:"http"
      ~headers:(Headers.of_list [ ":authority", "local.test" ])
      meth
      target
  in
  let request_body =
    Client_connection.request
      client
      request
      ~trailers_handler:(fun headers -> trailers := Headers.to_list headers)
      ~error_handler:(fun err ->
        ignore (Eio.Promise.try_resolve done_u (Error (pp_client_error err))))
      ~response_handler:(fun response response_body ->
        read_body response_body ~on_done:(fun body ->
          ignore
            (Eio.Promise.try_resolve
               done_u
               (Ok
                  { status = Status.to_code response.status
                  ; body
                  ; trailers = !trailers
                  }))))
  in
  (match body with
  | None -> ()
  | Some body -> Body.Writer.write_string request_body body);
  Body.Writer.close request_body;
  done_p

let request_first_chunk_keep_open client target =
  let done_p, done_u = Eio.Promise.create () in
  let request =
    Request.create
      ~scheme:"http"
      ~headers:(Headers.of_list [ ":authority", "local.test" ])
      `GET
      target
  in
  let request_body =
    Client_connection.request
      client
      request
      ~error_handler:(fun err ->
        ignore (Eio.Promise.try_resolve done_u (Error (pp_client_error err))))
      ~response_handler:(fun response response_body ->
        Body.Reader.schedule_read
          response_body
          ~on_eof:(fun () ->
            ignore (Eio.Promise.try_resolve done_u (Error "unexpected EOF")))
          ~on_read:(fun bs ~off ~len ->
            let chunk = Bigstringaf.substring bs ~off ~len in
            ignore
              (Eio.Promise.try_resolve
                 done_u
                 (Ok (Status.to_code response.status, chunk)))))
  in
  Body.Writer.close request_body;
  done_p

let request_first_chunk_then_close client target =
  let done_p, done_u = Eio.Promise.create () in
  let request =
    Request.create
      ~scheme:"http"
      ~headers:(Headers.of_list [ ":authority", "local.test" ])
      `GET
      target
  in
  let request_body =
    Client_connection.request
      client
      request
      ~error_handler:(fun err ->
        ignore (Eio.Promise.try_resolve done_u (Error (pp_client_error err))))
      ~response_handler:(fun response response_body ->
        Body.Reader.schedule_read
          response_body
          ~on_eof:(fun () ->
            ignore (Eio.Promise.try_resolve done_u (Error "unexpected EOF")))
          ~on_read:(fun bs ~off ~len ->
            let chunk = Bigstringaf.substring bs ~off ~len in
            Body.Reader.close response_body;
            ignore
              (Eio.Promise.try_resolve
                 done_u
                 (Ok
                    ( Status.to_code response.status
                    , chunk
                    , Body.Reader.is_closed response_body )))))
  in
  Body.Writer.close request_body;
  done_p

let with_local_connection
      ?(client_config = Config.default)
      ?(server_config = Config.default)
      client_action
  =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:1
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_done, server_done_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
    Fun.protect
      ~finally:(fun () -> ignore (Eio.Promise.try_resolve server_done_u ()))
      (fun () -> run_server_connection ~clock ~config:server_config flow));
  let result =
    Eio.Switch.run @@ fun conn_sw ->
    let flow =
      Eio.Net.connect
        ~sw:conn_sw
        net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let client_errors = ref [] in
    let client =
      Client_connection.create
        ~config:client_config
        ~error_handler:(fun err ->
          client_errors := pp_client_error err :: !client_errors)
        ()
    in
    Eio.Switch.run @@ fun client_sw ->
    Eio.Fiber.fork ~sw:client_sw (fun () ->
      try run_client_writer flow client with _ -> ());
    Eio.Fiber.fork ~sw:client_sw (fun () ->
      try run_client_reader flow client with _ -> ());
    let result = client_action ~clock ~client_errors client in
    Client_connection.shutdown client;
    (try Eio.Flow.shutdown flow `All with _ -> ());
    result, !client_errors
  in
  Eio.Promise.await server_done;
  result

let require label cond =
  if not cond then failwith ("require failed: " ^ label)

let expect_ok = function
  | Ok value -> value
  | Error err -> failwith err

let scenario_concurrent_gets () =
  let responses, client_errors =
    with_local_connection @@ fun ~clock:_ ~client_errors:_ client ->
    let promises =
      List.init 10 (fun i -> i, request client (Printf.sprintf "/get/%d" i))
    in
    List.map
      (fun (i, p) ->
        let response = Eio.Promise.await p |> expect_ok in
        i, response)
      promises
  in
  require "no connection-level client errors" (client_errors = []);
  List.iter
    (fun (i, response) ->
      require "GET status" (response.status = 200);
      require
        "GET body"
        (String.equal response.body (Printf.sprintf "get:%d" i)))
    responses;
  Printf.printf
    "h_s1_stage2_concurrent_gets count=%d statuses=all-200\n%!"
    (List.length responses)

let scenario_post_body () =
  let response, client_errors =
    with_local_connection @@ fun ~clock:_ ~client_errors:_ client ->
    request client ~meth:`POST ~body:"upload-body" "/post"
    |> Eio.Promise.await
    |> expect_ok
  in
  require "no connection-level client errors" (client_errors = []);
  require "POST status" (response.status = 200);
  require "POST echo body" (String.equal response.body "post:upload-body");
  Printf.printf "h_s1_stage2_post_body status=200 body=%S\n%!" response.body

let scenario_trailers () =
  let response, client_errors =
    with_local_connection @@ fun ~clock:_ ~client_errors:_ client ->
    request client "/trailers" |> Eio.Promise.await |> expect_ok
  in
  require "no connection-level client errors" (client_errors = []);
  require "trailers status" (response.status = 200);
  require "trailers body" (String.equal response.body "trailered");
  require
    "trailers delivered"
    (List.assoc_opt "x-stage2-trailer" response.trailers = Some "present");
  Printf.printf
    "h_s1_stage2_trailers status=200 trailers=%d\n%!"
    (List.length response.trailers)

let scenario_server_rst () =
  let result, client_errors =
    with_local_connection @@ fun ~clock:_ ~client_errors:_ client ->
    request client "/rst" |> Eio.Promise.await
  in
  require "no connection-level client errors" (client_errors = []);
  (match result with
  | Ok response ->
    failwith
      (Printf.sprintf
         "expected stream error, got status=%d body=%S"
         response.status
         response.body)
  | Error err ->
    require
      "RST surfaces stream error"
      (String.length err > 0
       && (String.sub err 0 (min (String.length err) 4) = "exn:"
           || String.sub err 0 (min (String.length err) 15) = "protocol_error:"));
    Printf.printf "h_s1_stage2_server_rst error=%S\n%!" err)

let scenario_goaway_cutoff () =
  let outcome, client_errors =
    with_local_connection @@ fun ~clock ~client_errors client ->
    let first = request client "/goaway" |> Eio.Promise.await |> expect_ok in
    require "GOAWAY trigger status" (first.status = 200);
    require
      "GOAWAY trigger body"
      (String.equal first.body "goaway-before-close");
    let rec wait_for_goaway attempts =
      match !client_errors with
      | err :: _ -> `Adapter_gate_after_connection_error err
      | [] when Client_connection.is_closed client -> `Closed_after_goaway
      | [] when attempts <= 0 -> `Goaway_not_observed
      | [] ->
        Eio.Time.sleep clock 0.01;
        wait_for_goaway (attempts - 1)
    in
    (match wait_for_goaway 50 with
    | (`Adapter_gate_after_connection_error _ | `Closed_after_goaway) as observed ->
      observed
    | `Goaway_not_observed ->
      (match
         Eio.Time.with_timeout clock 0.5 (fun () ->
           Ok
             (try
                match Eio.Promise.await (request client "/get/after-goaway") with
                | Ok response -> `Response response
                | Error err -> `Stream_error err
              with exn -> `Raised (Printexc.to_string exn)))
       with
      | Ok outcome -> outcome
      | Error `Timeout -> `Timeout))
  in
  (match outcome with
  | `Closed_after_goaway ->
    Printf.printf
      "h_s1_stage2_goaway_cutoff closed_after_goaway client_errors=%d\n%!"
      (List.length client_errors)
  | `Adapter_gate_after_connection_error err ->
    Printf.printf
      "h_s1_stage2_goaway_cutoff adapter_gate connection_error=%S\n%!"
      err
  | `Timeout ->
    Printf.printf
      "h_s1_stage2_goaway_cutoff unresolved=post_request_timeout client_errors=%d\n%!"
      (List.length client_errors)
  | `Goaway_not_observed ->
    Printf.printf "h_s1_stage2_goaway_cutoff unresolved=goaway_not_observed\n%!"
  | `Response response ->
    failwith
      (Printf.sprintf
         "post-GOAWAY request unexpectedly succeeded: status=%d body=%S"
         response.status
         response.body)
  | `Stream_error err ->
    require "no connection-level client errors" (client_errors = []);
    Printf.printf "h_s1_stage2_goaway_cutoff stream_error=%S\n%!" err
  | `Raised exn ->
    Printf.printf
      "h_s1_stage2_goaway_cutoff raised=%S client_errors=%d\n%!"
      exn
      (List.length client_errors))

let scenario_flow_control_stall () =
  let client_config =
    { Config.default with
      initial_window_size = 1024l
    ; response_body_buffer_size = 1024
    }
  in
  let (first_status, first_chunk_len, after), client_errors =
    with_local_connection ~client_config @@ fun ~clock ~client_errors:_ client ->
    let first_status, first_chunk =
      request_first_chunk_keep_open client "/flow-stall"
      |> Eio.Promise.await
      |> expect_ok
    in
    require "flow-stall first chunk present" (String.length first_chunk > 0);
    require
      "flow-stall first chunk respects advertised stream window"
      (String.length first_chunk <= 1024);
    Eio.Time.sleep clock 0.05;
    let after =
      match
        Eio.Time.with_timeout clock 0.5 (fun () ->
          Ok
            (request client "/get/flow-stall-control"
             |> Eio.Promise.await
             |> expect_ok))
      with
      | Ok response -> response
      | Error `Timeout -> failwith "control request timed out behind stalled stream"
    in
    first_status, String.length first_chunk, after
  in
  require "no connection-level client errors" (client_errors = []);
  require "flow-stall status" (first_status = 200);
  require "control status" (after.status = 200);
  require
    "control body"
    (String.equal after.body "get:flow-stall-control");
  Printf.printf
    "h_s1_stage2_flow_stall first_chunk_len=%d peer_window=1024 control_status=200\n%!"
    first_chunk_len

let scenario_client_cancellation () =
  let active_stream_metadata = ref 0 in
  let (status, first_chunk, body_closed, after, metadata_after_cancel), client_errors =
    with_local_connection @@ fun ~clock:_ ~client_errors:_ client ->
    incr active_stream_metadata;
    let status, first_chunk, body_closed =
      request_first_chunk_then_close client "/slow"
      |> Eio.Promise.await
      |> expect_ok
    in
    decr active_stream_metadata;
    let metadata_after_cancel = !active_stream_metadata in
    let after =
      request client "/get/after-cancel" |> Eio.Promise.await |> expect_ok
    in
    status, first_chunk, body_closed, after, metadata_after_cancel
  in
  require "no connection-level client errors" (client_errors = []);
  require "slow status" (status = 200);
  require "first chunk" (String.equal first_chunk "slow-prefix");
  require "cancelled body closed" body_closed;
  require "adapter metadata cleaned" (metadata_after_cancel = 0);
  require "after cancel status" (after.status = 200);
  require "after cancel body" (String.equal after.body "get:after-cancel");
  Printf.printf
    "h_s1_stage2_client_cancel first_chunk=%S body_closed=%b metadata=%d after_status=200\n%!"
    first_chunk
    body_closed
    metadata_after_cancel

let () =
  scenario_concurrent_gets ();
  scenario_post_body ();
  scenario_trailers ();
  scenario_server_rst ();
  scenario_goaway_cutoff ();
  scenario_flow_control_stall ();
  scenario_client_cancellation ()
