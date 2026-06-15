open Test_eta_http_support

module H2_core = Eta_http.H2

let h2_request path : H2_core.Connection.Client.request =
  {
    meth = "GET";
    scheme = Some "https";
    authority = Some "api.example.test";
    path;
    headers = [];
  }

let h2_frame_length data off =
  (Char.code data.[off] lsl 16)
  lor (Char.code data.[off + 1] lsl 8)
  lor Char.code data.[off + 2]

let h2_frame_stream_id data off =
  ((Char.code data.[off + 5] land 0x7f) lsl 24)
  lor (Char.code data.[off + 6] lsl 16)
  lor (Char.code data.[off + 7] lsl 8)
  lor Char.code data.[off + 8]

let find_h2_frame ~frame_type ~stream_id data =
  let preface_len = String.length "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" in
  let rec loop off =
    if off + 9 > String.length data then None
    else
      let len = h2_frame_length data off in
      let total = 9 + len in
      if total < 9 || off + total > String.length data then None
      else if
        Char.code data.[off + 3] = frame_type
        && h2_frame_stream_id data off = stream_id
      then Some off
      else loop (off + total)
  in
  loop preface_len

let test_h2_writer_drains_client_preface_and_request () =
  let client =
    H2_core.Connection.Client.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request_body =
    H2_core.Connection.Client.request client ~stream_id:1 (h2_request "/writer")
      ~error_handler:(fun _ _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2_core.Body.Writer.close request_body;
  let buffer = Buffer.create 256 in
  let flow = Eio.Flow.buffer_sink buffer in
  (match Eta_http_eio.H2.Writer.drain_client ~flow client with
  | Yield { written } ->
      Alcotest.(check bool) "wrote bytes" true (written > 24)
  | Close { code; _ } -> Alcotest.failf "unexpected close code=%d" code);
  let output = Buffer.contents buffer in
  let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" in
  Alcotest.(check string) "connection preface" preface
    (String.sub output 0 (String.length preface));
  match Eta_http_eio.H2.Writer.drain_client ~flow client with
  | Yield { written = 0 } -> ()
  | Yield { written } -> Alcotest.failf "unexpected extra write=%d" written
  | Close { code; _ } -> Alcotest.failf "unexpected second close code=%d" code

let test_h2_writer_sends_end_stream_on_empty_request_headers () =
  let client =
    H2_core.Connection.Client.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request_body =
    H2_core.Connection.Client.request client ~stream_id:1 ~end_stream:true
      (h2_request "/empty")
      ~error_handler:(fun _ _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  Alcotest.(check bool) "request body closed" true
    (H2_core.Body.Writer.is_closed request_body);
  (match H2_core.Body.Writer.write_string request_body "x" with
  | Error H2_core.Error_code.Stream_closed -> ()
  | Ok () -> Alcotest.fail "closed end_stream request body accepted a write"
  | Error error ->
      Alcotest.failf "unexpected request body error: %a"
        H2_core.Error_code.pp_hum error);
  let buffer = Buffer.create 256 in
  let flow = Eio.Flow.buffer_sink buffer in
  (match Eta_http_eio.H2.Writer.drain_client ~flow client with
  | Yield { written } ->
      Alcotest.(check bool) "wrote bytes" true (written > 24)
  | Close { code; _ } -> Alcotest.failf "unexpected close code=%d" code);
  let output = Buffer.contents buffer in
  match find_h2_frame ~frame_type:0x1 ~stream_id:1 output with
  | None -> Alcotest.fail "missing request HEADERS frame"
  | Some off ->
      let flags = Char.code output.[off + 4] in
      Alcotest.(check bool) "HEADERS has END_STREAM" true
        (flags land H2_core.Frame.Flags.end_stream <> 0)

let test_h2_writer_blocked_write_teardown () =
  with_test_clock @@ fun _sw _clock rt ->
  let client =
    H2_core.Connection.Client.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request_body =
    H2_core.Connection.Client.request client ~stream_id:1
      (h2_request "/blocked-writer")
      ~error_handler:(fun _ _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2_core.Body.Writer.close request_body;
  let started = Eta.Channel.create ~capacity:1 () in
  let blocked = Eta.Channel.create ~capacity:1 () in
  let write_started = ref false in
  let write _iovecs =
    let signal =
      if !write_started then Eta.Effect.unit
      else (
        write_started := true;
        Eta.Channel.try_send started () |> Eta.Effect.map (fun _ -> ()))
    in
    signal
    |> Eta.Effect.bind (fun () ->
           Eta.Channel.recv blocked |> Eta.Effect.map (fun () -> 1))
  in
  let eff =
    Eta.Supervisor.scoped
      {
        run =
          (fun supervisor ->
            let open Eta.Supervisor.Scope in
            let* _writer =
              start supervisor
                (lift (Eta_http_eio.H2.Writer.run_client ~write client))
            in
            let* _ = lift (Eta.Channel.recv started) in
            pure ());
      }
  in
  (match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "blocked writer scope failed: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed -> Format.pp_print_string fmt "closed"
          | `Closed_with_error _ ->
              Format.pp_print_string fmt "closed_with_error"))
        cause);
  Alcotest.(check bool) "write started" true !write_started
