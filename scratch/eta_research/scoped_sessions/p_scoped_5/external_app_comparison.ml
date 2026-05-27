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
  let stop = Supervisor.Scope.stop

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

let rec wait_until predicate =
  if predicate () then Effect.unit
  else
    Effect.delay (Duration.ms 1) Effect.unit
    |> Effect.bind (fun () -> wait_until predicate)

let app_background_loop () =
  let ticks = Atomic.make 0 in
  let finalized = Atomic.make false in
  let rec ticker () =
    Effect.sync (fun () -> Atomic.incr ticks)
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1) Effect.unit)
    |> Effect.bind ticker
  in
  let loop =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set finalized true))
    |> Effect.bind ticker
  in
  Effect.with_background loop (fun () ->
      wait_until (fun () -> Atomic.get ticks >= 2)
      |> Effect.map (fun () -> Atomic.get finalized))

let app_explicit_await () =
  let child = Effect.delay (Duration.ms 1) (Effect.pure "ready") in
  Fiber_scope.with_fiber child
    {
      run =
        (fun fiber ->
          let open Fiber_scope in
          let* value = await fiber in
          pure value);
    }

let app_explicit_stop () =
  let finalized = Atomic.make false in
  let child =
    Effect.acquire_release ~acquire:Effect.unit
      ~release:(fun () -> Effect.sync (fun () -> Atomic.set finalized true))
    |> Effect.bind (fun () -> Effect.sync Eio.Fiber.await_cancel)
  in
  Fiber_scope.with_fiber child
    {
      run =
        (fun fiber ->
          let open Fiber_scope in
          let* () = lift (Effect.delay (Duration.ms 1) Effect.unit) in
          let* () = stop fiber in
          lift (Effect.sync (fun () -> Atomic.get finalized)));
    }

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let check label expect = function
    | Exit.Ok value when String.equal value expect -> ()
    | Exit.Ok value ->
        Format.eprintf "%s: expected %S got %S@." label expect value;
        exit 1
    | Exit.Error _ ->
        Format.eprintf "%s: unexpected failure@." label;
        exit 1
  in
  let bg = Runtime.run rt (app_background_loop () |> Effect.map string_of_bool) in
  check "background" "false" bg;
  let awaited = Runtime.run rt (app_explicit_await ()) in
  check "await" "ready" awaited;
  let stopped =
    Runtime.run rt (app_explicit_stop () |> Effect.map string_of_bool)
  in
  check "stop" "true" stopped;
  print_endline "external_app_comparison: ok"
