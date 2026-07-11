open Test_eta_http_support

let h2_iovecs_to_string iovecs =
  let len = Eta_http_h2.Iovec.lengthv iovecs in
  let bytes = Bytes.create len in
  let dst_off = ref 0 in
  List.iter
    (fun ({ Eta_http_h2.Iovec.buffer; off; len } :
            Bigstringaf.t Eta_http_h2.Iovec.t) ->
      Bigstringaf.blit_to_bytes buffer ~src_off:off bytes ~dst_off:!dst_off
        ~len;
      dst_off := !dst_off + len)
    iovecs;
  Bytes.unsafe_to_string bytes

let h2_feed_client client data =
  let rec loop off =
      if off < String.length data then (
        let len = String.length data - off in
        let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = Eta_http_h2.Connection.read client buffer ~off:0 ~len in
      if consumed <= 0 then Alcotest.fail "client consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let h2_feed_server server data =
  let rec loop off =
      if off < String.length data then (
        let len = String.length data - off in
        let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = Eta_http_h2.Connection.read server buffer ~off:0 ~len in
      if consumed <= 0 then Alcotest.fail "server consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let rec h2_drain_server_output server acc =
  match Eta_http_h2.Connection.next_write_operation server with
  | Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      Eta_http_h2.Connection.report_write_result server (`Ok (String.length data));
      h2_drain_server_output server (data :: acc)
  | Yield -> String.concat "" (List.rev acc)
  | Close _ ->
      Eta_http_h2.Connection.report_write_result server `Closed;
      String.concat "" (List.rev acc)

let h2_drain_client_to_server client server =
  match Eta_http_h2.Connection.next_write_operation client with
  | Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      Eta_http_h2.Connection.report_write_result client (`Ok (String.length data));
      h2_feed_server server data;
      true
  | Yield -> false
  | Close _ ->
      Eta_http_h2.Connection.report_write_result client `Closed;
      false

let h2_drain_server_to_client server client =
  match Eta_http_h2.Connection.next_write_operation server with
  | Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      Eta_http_h2.Connection.report_write_result server (`Ok (String.length data));
      h2_feed_client client data;
      true
  | Yield -> false
  | Close _ ->
      Eta_http_h2.Connection.report_write_result server `Closed;
      false

let h2_pump_pair ?(limit = 10_000) client server =
  let rec loop remaining =
    if remaining <= 0 then Alcotest.fail "h2 pump did not quiesce"
    else
      let client_progress = h2_drain_client_to_server client server in
      let server_progress = h2_drain_server_to_client server client in
      if client_progress || server_progress then loop (remaining - 1)
  in
  loop limit

let h2_eta_iovecs_to_string = h2_iovecs_to_string

let h2_feed_eta_client = h2_feed_client

let h2_drain_eta_client_to_server = h2_drain_client_to_server

let h2_drain_server_to_eta_client = h2_drain_server_to_client

let h2_pump_eta_client_server = h2_pump_pair

let h2_cstruct_chunks ~chunk_size data =
  let rec loop off acc =
    if off >= String.length data then List.rev acc
    else
      let len = min chunk_size (String.length data - off) in
      let buffer = Bigstringaf.of_string ~off ~len data in
      loop (off + len) (Cstruct.of_bigarray buffer :: acc)
  in
  loop 0 []

type h2_read_result = {
  mutable status : int option;
  body : Buffer.t;
  mutable eof : bool;
  mutable client_errors : int;
  mutable stream_errors : int;
}

let h2_read_result () =
  {
    status = None;
    body = Buffer.create 32;
    eof = false;
    client_errors = 0;
    stream_errors = 0;
  }

let h2_schedule_eta_body result body =
  let rec loop () =
    Eta_http_h2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> result.eof <- true)
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string result.body (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let h2_core_request ?(meth = "GET") ?(target = "/")
    ?(authority = "api.example.test") () :
    Eta_http_h2.Connection.Client.request =
  {
    meth;
    scheme = Some "https";
    authority = Some authority;
    path = target;
    headers = [];
  }

let h2_pp_client_error (error : Eta_http_h2.Connection.error) =
  Format.asprintf "protocol_error:%a:%s" Eta_http_h2.Error_code.pp_hum
    error.error_code error.message

type h2_mux_result = {
  mutable mux_status : int option;
  mux_body : Buffer.t;
  mutable mux_eof : bool;
  mutable mux_stream_errors : string list;
  mutable mux_client_errors : string list;
  mutable mux_stream : Eta_http_eio.H2.Multiplexer.stream option;
  mutable mux_release : Eta_http_h2.Stream_state.release option;
}

let h2_mux_result () =
  {
    mux_status = None;
    mux_body = Buffer.create 128;
    mux_eof = false;
    mux_stream_errors = [];
    mux_client_errors = [];
    mux_stream = None;
    mux_release = None;
  }

let h2_mux_create ?max_concurrent ?config result () =
  Eta_http_eio.H2.Multiplexer.create ?max_concurrent ?config
    ~error_handler:(fun error ->
      result.mux_client_errors <- h2_pp_client_error error :: result.mux_client_errors)
    ()

let h2_schedule_mux_body mux result stream body =
  let rec loop () =
    Eta_http_h2.Body.Reader.schedule_read body
      ~on_eof:(fun () ->
        Eta_http_eio.H2.Multiplexer.mark_complete mux stream;
        result.mux_eof <- true)
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string result.mux_body (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let h2_method_to_string = function
  | `GET -> "GET"
  | `HEAD -> "HEAD"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `DELETE -> "DELETE"
  | `CONNECT -> "CONNECT"
  | `OPTIONS -> "OPTIONS"
  | `TRACE -> "TRACE"
  | `PATCH -> "PATCH"
  | `Other method_ -> method_

let h2_open_mux_request ?(meth = `GET) ?body ?(target = "/") ?(tag = 0) mux
    result =
  let request : Eta_http_h2.Connection.Client.request =
    {
      meth = h2_method_to_string meth;
      scheme = Some "https";
      authority = Some "api.example.test";
      path = target;
      headers = [];
    }
  in
  match
    Eta_http_eio.H2.Multiplexer.request mux ~tag request
      ~error_handler:(fun stream error ->
        result.mux_stream <- Some stream;
        result.mux_stream_errors <-
          h2_pp_client_error error :: result.mux_stream_errors)
      ~response_handler:(fun stream response response_body ->
        result.mux_stream <- Some stream;
        result.mux_status <- Some response.status;
        h2_schedule_mux_body mux result stream response_body)
  with
  | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
      Error `Admission_rejected
  | Error Eta_http_eio.H2.Multiplexer.Connection_closed -> Error `Connection_closed
  | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
      Error (`Request_failed message)
  | Ok opened ->
      result.mux_stream <- Some opened.stream;
      (match body with
      | None -> ()
      | Some body ->
          ignore (Eta_http_h2.Body.Writer.write_string opened.request_body body));
      Eta_http_h2.Body.Writer.close opened.request_body;
      Ok opened

let h2_server_response ?(headers = []) ?(body = `String "") status :
    Eta_http_h2.Connection.Server.response =
  { status; headers; body; trailers = Lazy.from_val [] }

let h2_create_server ?config request_handler =
  Eta_http_h2.Connection.Server.create ?config ~request_handler
    ~error_handler:(fun error ->
      Alcotest.failf "unexpected h2 server error: %a %s"
        Eta_http_h2.Error_code.pp_hum error.error_code error.message)
    ()

let h2_server_read_body reqd ~on_done =
  let body = Eta_http_h2.Connection.Server.Reqd.request_body reqd in
  let buffer = Buffer.create 4096 in
  let rec loop () =
    Eta_http_h2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> on_done (Buffer.contents buffer))
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string buffer (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()


let h2_frame_header ~length ~frame_type ~flags ~stream_id =
  Eta_http_h2.Frame.header ~length ~frame_type:(Other frame_type) ~flags
    ~stream_id

let h2_uint32 = Eta_http_h2.Frame.uint32

let h2_settings_frame = Eta_http_h2.Frame.settings

let h2_goaway_no_error = Eta_http_h2.Frame.goaway_no_error

let h2_payload = Eta_http_h2.Frame.payload

let h2_observe_security data =
  let security = Eta_http_h2.Security.create () in
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length data) data in
  match
    Eta_http_h2.Security.observe_result security bs ~off:0
      ~len:(String.length data) ~now_ms:0L
  with
  | Eta_http_h2.Security.Pass -> None
  | Eta_http_h2.Security.Connection_error { kind; _ }
  | Eta_http_h2.Security.Stream_error { kind; _ }
  | Eta_http_h2.Security.Policy_close { kind; _ } ->
      Some kind
