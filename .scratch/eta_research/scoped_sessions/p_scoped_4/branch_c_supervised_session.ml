open Eta

type session_error = Closed | Reader_failed

type session = {
  mutable callback_used : bool;
  mutable resource_released : bool;
  mutable reader_finalized : bool;
}

let open_session =
  Effect.sync (fun () ->
      { callback_used = false; resource_released = false; reader_finalized = false })

let close_session session =
  Effect.sync (fun () -> session.resource_released <- true)

let reader_loop session =
  Effect.acquire_release ~acquire:Effect.unit
    ~release:(fun () -> Effect.sync (fun () -> session.reader_finalized <- true))
  |> Effect.bind (fun () -> Effect.sync Eio.Fiber.await_cancel)

let with_session use =
  Effect.scoped
    (Effect.acquire_release ~acquire:open_session ~release:close_session
    |> Effect.bind (fun session ->
           Supervisor.scoped
             {
               run =
                 (fun (type s) sup ->
                   let open Supervisor.Scope in
                   let* (_reader : (s, session_error, unit) Supervisor.child) =
                     start sup (lift (reader_loop session))
                   in
                   lift (use session));
             }))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let observed = ref None in
  let program =
    with_session (fun session ->
        observed := Some session;
        Effect.sync (fun () -> session.callback_used <- true))
  in
  match Runtime.run rt program with
  | Exit.Error cause ->
      Format.eprintf "unexpected failure: %a@."
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<session-error>"))
        cause;
      exit 1
  | Exit.Ok () -> (
      match !observed with
      | None ->
          Format.eprintf "callback did not receive session@.";
          exit 1
      | Some session ->
          if
            session.callback_used && session.reader_finalized
            && session.resource_released
          then print_endline "branch_c_supervised_session: ok"
          else (
            Format.eprintf
              "bad lifecycle: callback_used=%b reader_finalized=%b resource_released=%b@."
              session.callback_used session.reader_finalized session.resource_released;
            exit 1))

