open Eta

module Fiber_scope = struct
  type ('s, 'a, 'err) fiber = ('s, 'err, 'a) Supervisor.child
  type ('s, 'a, 'err) t = ('s, 'a, 'err) Supervisor.Scope.t

  let lift = Supervisor.Scope.lift
  let pure = Supervisor.Scope.pure
  let bind = Supervisor.Scope.bind
  let ( let* ) = Supervisor.Scope.( let* )
  let await = Supervisor.Scope.await
  let cancel = Supervisor.Scope.cancel

  type ('child, 'a, 'err) body = {
    run : 's. ('s, 'child, 'err) fiber -> ('s, 'a, 'err) t;
  }

  let with_fiber ?name child body =
    let child = match name with None -> child | Some name -> Effect.named name child in
    Supervisor.scoped
      {
        run =
          (fun sup ->
            let open Supervisor.Scope in
            let* fiber = start sup (lift child) in
            body.run fiber);
      }
end

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let finalized = Atomic.make false in
  let child =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set finalized true))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1) (Effect.pure 42))
  in
  let program =
    Fiber_scope.with_fiber ~name:"external.worker" child
      {
        run =
          (fun fiber ->
            let open Fiber_scope in
            let* value = await fiber in
            pure value);
      }
  in
  match Runtime.run rt program with
  | Exit.Ok 42 when Atomic.get finalized ->
      print_endline "fiber_scope_with_handle: ok"
  | Exit.Ok value ->
      Format.eprintf
        "fiber_scope_with_handle: bad value/finalizer value=%d finalized=%b@."
        value (Atomic.get finalized);
      exit 1
  | Exit.Error _ ->
      Format.eprintf "fiber_scope_with_handle: unexpected failure@.";
      exit 1
