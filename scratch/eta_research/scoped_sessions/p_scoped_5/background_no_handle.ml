open Eta

let wait_until predicate =
  let rec loop () =
    if predicate () then Effect.unit
    else Effect.delay (Duration.ms 1) Effect.unit |> Effect.bind loop
  in
  loop ()

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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
  let program =
    Effect.with_background ~name:"external.ticker" loop (fun () ->
        wait_until (fun () -> Atomic.get ticks >= 2))
  in
  match Runtime.run rt program with
  | Exit.Error _ ->
      Format.eprintf "background_no_handle: unexpected failure@.";
      exit 1
  | Exit.Ok () ->
      if Atomic.get finalized then print_endline "background_no_handle: ok"
      else (
        Format.eprintf "background_no_handle: background finalizer did not run@.";
        exit 1)
