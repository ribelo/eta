open H2

type response =
  { status : int
  ; body_len : int
  }

let host_name = "nghttp2.org"

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let string_of_tls_version = function
  | `TLS_1_0 -> "tls10"
  | `TLS_1_1 -> "tls11"
  | `TLS_1_2 -> "tls12"
  | `TLS_1_3 -> "tls13"

let ca_authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

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

let run_client_reader flow client =
  let rec loop () =
    match Client_connection.next_read_operation client with
    | `Read ->
      let buf = Cstruct.create 0x4000 in
      let n = Eio.Flow.single_read flow buf in
      let data = Cstruct.to_string (Cstruct.sub buf 0 n) in
      let bs = Bigstringaf.of_string ~off:0 ~len:n data in
      ignore (Client_connection.read client bs ~off:0 ~len:n : int);
      loop ()
    | `Close -> ()
  in
  try loop () with End_of_file -> ()

let read_body body ~on_done =
  let len = ref 0 in
  let resolved = ref false in
  let finish () =
    if not !resolved then (
      resolved := true;
      on_done !len)
  in
  let rec loop () =
    if Body.Reader.is_closed body then finish ()
    else
      Body.Reader.schedule_read
        body
        ~on_eof:finish
        ~on_read:(fun _bs ~off:_ ~len:chunk_len ->
          len := !len + chunk_len;
          loop ())
  in
  loop ()

let request client =
  let done_p, done_u = Eio.Promise.create () in
  let request =
    Request.create
      ~scheme:"https"
      ~headers:
        (Headers.of_list
           [ ":authority", host_name
           ; "user-agent", "eta-hs1-nghttp2-smoke"
           ])
      `GET
      "/"
  in
  let request_body =
    Client_connection.request
      client
      request
      ~error_handler:(fun err ->
        ignore (Eio.Promise.try_resolve done_u (Error (pp_client_error err))))
      ~response_handler:(fun response response_body ->
        read_body response_body ~on_done:(fun body_len ->
          ignore
            (Eio.Promise.try_resolve
               done_u
               (Ok { status = Status.to_code response.status; body_len }))))
  in
  Body.Writer.close request_body;
  done_p

let run env =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock 10.0 (fun () ->
      Ok
        (Eio.Switch.run @@ fun sw ->
         let addr =
           match Eio.Net.getaddrinfo_stream net host_name ~service:"443" with
           | [] -> failwith "no addresses for nghttp2.org:443"
           | addr :: _ -> addr
         in
         let raw_flow = Eio.Net.connect ~sw net addr in
         let tls_flow =
           Tls_eio.client_of_flow
             (Tls.Config.client
                ~authenticator:(ca_authenticator ())
                ~alpn_protocols:[ "h2"; "http/1.1" ]
                ~ciphers:Tls.Config.Ciphers.supported
                ())
             ~host:(host_exn host_name)
             raw_flow
         in
         let epoch =
           match Tls_eio.epoch tls_flow with
           | Ok epoch -> epoch
           | Error () -> failwith "TLS epoch unavailable"
         in
         if epoch.Tls.Core.alpn_protocol <> Some "h2" then
           failwith "nghttp2.org did not negotiate h2";
         let client_errors = ref [] in
         let client =
           Client_connection.create
             ~error_handler:(fun err ->
               client_errors := pp_client_error err :: !client_errors)
             ()
         in
         Eio.Fiber.fork ~sw (fun () ->
           try run_client_writer tls_flow client with _ -> ());
         Eio.Fiber.fork ~sw (fun () ->
           try run_client_reader tls_flow client with _ -> ());
         let response = Eio.Promise.await (request client) in
         Client_connection.shutdown client;
         Eio.Resource.close tls_flow;
         response, !client_errors, epoch.Tls.Core.protocol_version))
  with
  | Error `Timeout -> failwith "nghttp2.org h2 smoke timed out"
  | Ok (Error err, _client_errors, _version) -> failwith err
  | Ok (Ok response, client_errors, version) ->
    if client_errors <> [] then failwith "unexpected connection-level client errors";
    if response.status < 200 || response.status >= 300 then
      failwith (Printf.sprintf "unexpected HTTP status %d" response.status);
    Printf.printf
      "h_s1_stage1_nghttp2 status=%d alpn=h2 version=%s body_len=%d\n%!"
      response.status
      (string_of_tls_version version)
      response.body_len

let () = Eio_main.run run
