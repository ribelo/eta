open Eta

type session_error = Closed | Reader_failed

type session = {
  mutable close_called : bool;
  mutable reader_finalized : bool;
}

let with_session ~acquire ~release ~reader use =
  Effect.scoped
    (Effect.acquire_release ~acquire ~release
    |> Effect.bind (fun session ->
           Supervisor.scoped
             {
               run =
                 (fun (type s) sup ->
                   let open Supervisor.Scope in
                   let* (_reader : (s, session_error, unit) Supervisor.child) =
                     start sup (lift (reader session))
                   in
                   lift (use session));
             }))

let acquire =
  Effect.sync (fun () -> { close_called = false; reader_finalized = false })

let release session = Effect.sync (fun () -> session.close_called <- true)

let reader session =
  Effect.acquire_release ~acquire:Effect.unit
    ~release:(fun () -> Effect.sync (fun () -> session.reader_finalized <- true))
  |> Effect.bind (fun () -> Effect.sync Eio.Fiber.await_cancel)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let seen = ref None in
  let program =
    with_session ~acquire ~release ~reader (fun session ->
        seen := Some session;
        Effect.unit)
  in
  match Runtime.run rt program with
  | Exit.Error _ ->
      Format.eprintf "branch_b_local_wrapper: unexpected failure@.";
      exit 1
  | Exit.Ok () -> (
      match !seen with
      | Some session when session.close_called && session.reader_finalized ->
          print_endline "branch_b_local_wrapper: ok"
      | _ ->
          Format.eprintf "branch_b_local_wrapper: lifecycle invariant failed@.";
          exit 1)

