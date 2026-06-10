open Test_eta_http_support

let h2_iovecs_to_string iovecs =
  iovecs
  |> Eta_http_eio.H2.Writer.cstructs_of_iovecs
  |> List.map Cstruct.to_string
  |> String.concat ""

let h2_feed_client client data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = H2.Client_connection.read client buffer ~off:0 ~len in
      if consumed <= 0 then Alcotest.fail "client consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let h2_feed_server server data =
  let rec loop off =
    if off < String.length data then (
      let len = String.length data - off in
      let buffer = Bigstringaf.of_string ~off ~len data in
      let consumed = H2.Server_connection.read server buffer ~off:0 ~len in
      if consumed <= 0 then Alcotest.fail "server consumed no h2 bytes";
      loop (off + consumed))
  in
  loop 0

let rec h2_drain_server_output server acc =
  match H2.Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Server_connection.report_write_result server (`Ok (String.length data));
      h2_drain_server_output server (data :: acc)
  | `Yield -> String.concat "" (List.rev acc)
  | `Close _ ->
      H2.Server_connection.report_write_result server `Closed;
      String.concat "" (List.rev acc)

let h2_drain_client_to_server client server =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Client_connection.report_write_result client (`Ok (String.length data));
      h2_feed_server server data;
      true
  | `Yield -> false
  | `Close _ ->
      H2.Client_connection.report_write_result client `Closed;
      false

let h2_drain_server_to_client server client =
  match H2.Server_connection.next_write_operation server with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Server_connection.report_write_result server (`Ok (String.length data));
      h2_feed_client client data;
      true
  | `Yield -> false
  | `Close _ ->
      H2.Server_connection.report_write_result server `Closed;
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

let h2_schedule_body result body =
  let rec loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> result.eof <- true)
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string result.body (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let h2_pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
      Format.asprintf "protocol_error:%a:%s" H2.Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

type h2_mux_result = {
  mutable mux_status : int option;
  mux_body : Buffer.t;
  mutable mux_eof : bool;
  mutable mux_stream_errors : string list;
  mutable mux_client_errors : string list;
  mutable mux_stream : Eta_http_eio.H2.Multiplexer.stream option;
  mutable mux_release : Eta_http.H2.Stream_state.release option;
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
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () ->
        Eta_http_eio.H2.Multiplexer.mark_complete mux stream;
        result.mux_eof <- true)
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string result.mux_body (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()

let h2_open_mux_request ?(meth = `GET) ?body ?(target = "/") ?(tag = 0) mux
    result =
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      meth target
  in
  match
    Eta_http_eio.H2.Multiplexer.request mux ~tag request
      ~error_handler:(fun stream error ->
        result.mux_stream <- Some stream;
        result.mux_stream_errors <-
          h2_pp_client_error error :: result.mux_stream_errors)
      ~response_handler:(fun stream response response_body ->
        result.mux_stream <- Some stream;
        result.mux_status <- Some (H2.Status.to_code response.status);
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
      | Some body -> H2.Body.Writer.write_string opened.request_body body);
      H2.Body.Writer.close opened.request_body;
      Ok opened

let h2_server_read_body reqd ~on_done =
  let body = H2.Reqd.request_body reqd in
  let buffer = Buffer.create 4096 in
  let rec loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> on_done (Buffer.contents buffer))
      ~on_read:(fun bs ~off ~len ->
        Buffer.add_string buffer (Bigstringaf.substring bs ~off ~len);
        loop ())
  in
  loop ()


let h2_frame_header ~length ~frame_type ~flags ~stream_id =
  Eta_http.H2.Frame.header ~length ~frame_type:(Other frame_type) ~flags
    ~stream_id

let h2_uint32 = Eta_http.H2.Frame.uint32

let h2_settings_frame = Eta_http.H2.Frame.settings

let h2_goaway_no_error = Eta_http.H2.Frame.goaway_no_error

let h2_payload = Eta_http.H2.Frame.payload

let h2_observe_security data =
  let security = Eta_http.H2.Security.create () in
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length data) data in
  Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length data)
