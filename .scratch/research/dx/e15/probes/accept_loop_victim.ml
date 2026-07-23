open Eta

let install_cancel_handle slot eff =
  Effect.Expert.make ~capabilities:[ `Concurrency ] ~inherit_:eff
    ~leaf_name:"dx-e15.accept.cancel-handle" @@ fun context ->
  let contract = Effect.Expert.contract context in
  contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
  slot := Some (fun () -> contract.Runtime_contract.cancel cancel_context Exit);
  Effect.Expert.eval context eff

let expect_interrupt = function
  | Exit.Ok (Exit.Error (Cause.Interrupt _)) -> ()
  | Exit.Ok (Exit.Error cause) ->
      failwith
        (Format.asprintf "accept loop: expected interrupt, got %a"
           (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
           cause)
  | Exit.Ok (Exit.Ok ()) -> failwith "accept loop: cancellation was lost"
  | Exit.Error cause ->
      failwith
        (Format.asprintf "accept loop controller failed: %a"
           (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
           cause)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  let cancel_handle = ref None in
  let accepting, accepting_resolver = Eio.Promise.create () in
  let accept_once =
    Effect.sync (fun () ->
        Eio.Promise.resolve accepting_resolver ();
        Eio.Switch.run @@ fun connection_switch ->
        let flow, _peer = Eio.Net.accept ~sw:connection_switch socket in
        Eio.Flow.close flow)
    |> Effect.interruptible
  in
  let victim =
    Effect.uninterruptible accept_once
    |> Effect.to_exit
    |> install_cancel_handle cancel_handle
  in
  let result =
    Eio.Fiber.fork_promise ~sw (fun () -> Eta_eio.Runtime.run runtime victim)
  in
  Eio.Promise.await accepting;
  (match !cancel_handle with
  | Some cancel -> cancel ()
  | None -> failwith "accept loop: cancel handle was not installed");
  let result =
    try
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
          Eio.Promise.await_exn result)
    with Eio.Time.Timeout -> failwith "accept loop: interrupt timed out"
  in
  expect_interrupt result;
  print_endline "accept-loop-victim: INTERRUPTED";
  print_endline "accept-loop-victim: PASS"
