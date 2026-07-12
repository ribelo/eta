(* SIGTERM handling intentionally captures the Eio stop resolver. [Sys.Safe.signal]
   requires a portable handler closure under OxCaml, so this wrapper uses the
   ordinary process signal API and restores the previous handler after serving. *)
[@@@alert "-unsafe_multidomain"]

module S = Eta_http.Server

module Serve = struct
  let tcp_addr ~host ~port =
    let ip =
      match host with
      | "localhost" | "127.0.0.1" -> Eio.Net.Ipaddr.V4.loopback
      | "::1" -> Eio.Net.Ipaddr.V6.loopback
      | "0.0.0.0" -> Eio.Net.Ipaddr.V4.any
      | "::" -> Eio.Net.Ipaddr.V6.any
      | host -> Eio_unix.Net.Ipaddr.of_unix (Unix.inet_addr_of_string host)
    in
    `Tcp (ip, port)

  let with_readiness ?(ready_path = Some "/ready") ~ready handler request =
    match ready_path with
    | Some path when String.equal request.S.Request.path path ->
        Eta.Effect.pure
          (if ready () then S.Response.text ~status:200 "ready\n"
           else S.Response.text ~status:503 "draining\n")
    | None | Some _ -> handler request

  let resolve_once resolver =
    let resolved = Atomic.make false in
    fun () ->
      if Atomic.compare_and_set resolved false true then
        Eio.Promise.resolve resolver ()

  let run_with_stop ~sw ?external_stop run =
    let stop, resolver = Eio.Promise.create () in
    let resolve_stop = resolve_once resolver in
    let ready = Atomic.make true in
    (match external_stop with
    | None -> ()
    | Some external_stop_promise ->
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.await external_stop_promise;
            Atomic.set ready false;
            resolve_stop ()));
    let on_sigterm (_ : int) =
      Atomic.set ready false;
      resolve_stop ()
    in
    let previous =
      Sys.signal Sys.sigterm (Sys.Signal_handle on_sigterm)
      [@alert.unsafe_multidomain ""]
    in
    Fun.protect
      ~finally:(fun () ->
        ignore
          (Sys.signal Sys.sigterm previous
          [@alert.unsafe_multidomain ""]))
      (fun () -> run ~ready:(fun () -> Atomic.get ready) stop)

  let choose_addr ?(host = "127.0.0.1") ?(port = 8080) = function
    | Some addr -> addr
    | None -> tcp_addr ~host ~port

  let run_protocol run_server ~sw ~net ~clock ?time ?domain_manager ?domain_policy ?stop ?config
      ?runtime_factory ?on_error ?on_connection_close
      ?(ready_path = Some "/ready") ?(host = "127.0.0.1") ?(port = 8080)
      ?addr handler =
    let addr = choose_addr ~host ~port addr in
    run_with_stop ~sw ?external_stop:stop @@ fun ~ready stop ->
    let handler = with_readiness ~ready_path ~ready handler in
    run_server ~sw ~net ~clock ?time ?domain_manager ?domain_policy ~stop ?config
      ?runtime_factory ?on_error ?on_connection_close ~addr handler

  let h1 = run_protocol Eta_http_eio.Server.run_h1
  let h2c = run_protocol Eta_http_eio.Server.run_h2c
end
