open Test_eta_http_support

let test_h2_writer_preserves_iovec_slices () =
  let buffer = Bigstringaf.of_string ~off:0 ~len:10 "0123456789" in
  let iovecs = [ { H2.IOVec.buffer; off = 2; len = 4 } ] in
  match Http.H2.Writer.cstructs_of_iovecs iovecs with
  | [ slice ] ->
      Alcotest.(check int) "slice len" 4 (Cstruct.length slice);
      Alcotest.(check string) "slice bytes" "2345" (Cstruct.to_string slice)
  | _ -> Alcotest.fail "expected one cstruct slice"

let test_h2_writer_drains_client_preface_and_request () =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/writer"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2.Body.Writer.close request_body;
  let buffer = Buffer.create 256 in
  let flow = Eio.Flow.buffer_sink buffer in
  (match Http.H2.Writer.drain_client ~flow client with
  | Yield { written } ->
      Alcotest.(check bool) "wrote bytes" true (written > 24)
  | Close { code; _ } -> Alcotest.failf "unexpected close code=%d" code);
  let output = Buffer.contents buffer in
  let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" in
  Alcotest.(check string) "connection preface" preface
    (String.sub output 0 (String.length preface));
  match Http.H2.Writer.drain_client ~flow client with
  | Yield { written = 0 } -> ()
  | Yield { written } -> Alcotest.failf "unexpected extra write=%d" written
  | Close { code; _ } -> Alcotest.failf "unexpected second close code=%d" code

let test_h2_writer_blocked_write_teardown () =
  Test.with_test_clock @@ fun _sw _clock rt ->
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected client h2 error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/blocked-writer"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> Alcotest.fail "unexpected stream h2 error")
      ~response_handler:(fun _ _ -> ())
  in
  H2.Body.Writer.close request_body;
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
  let effect =
    Eta.Supervisor.scoped
      {
        run =
          (fun supervisor ->
            let open Eta.Supervisor.Scope in
            let* _writer =
              start supervisor
                (lift (Http.H2.Writer.run_client ~write client))
            in
            let* _ = lift (Eta.Channel.recv started) in
            pure ());
      }
  in
  (match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "blocked writer scope failed: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed -> Format.pp_print_string fmt "closed"
          | `Closed_with_error _ ->
              Format.pp_print_string fmt "closed_with_error"))
        cause);
  Alcotest.(check bool) "write started" true !write_started

