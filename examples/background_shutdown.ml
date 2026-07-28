open Eta

type error = [ `Unexpected ] [@@deriving eta_error]

let require label condition =
  if not condition then failwith ("background shutdown check failed: " ^ label)

let wait_until label f =
  let rec loop attempts =
    if f () then ()
    else if attempts = 0 then failwith ("timed out waiting for " ^ label)
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 1_000

let worker stop done_ started flushed =
  let open Syntax in
  Effect.named ~error_pp:pp_error "app.flush"
    (let* () = Effect.sync (fun () -> started := true) in
     let* () = Effect.sync (fun () -> Eio.Promise.await stop) in
     Effect.sync (fun () ->
         flushed := true;
         Eio.Promise.resolve done_ ()))

let run_ok rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Format.eprintf "background shutdown failed: %a@."
        (Cause.pp pp_error) cause;
      exit 1

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let stop, resolve_stop = Eio.Promise.create () in
  let done_, resolve_done = Eio.Promise.create () in
  let started = ref false in
  let flushed = ref false in
  let before = ref true in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  (* Long-lived work belongs to the explicit top-level application scope:
     [with_background] owns the worker while the body runs, the body signals
     stop and explicitly waits for the worker to finish before the scope
     exits. No runtime-owned daemon and no [Runtime.drain] needed. *)
  run_ok rt
    (Effect.with_background ~name:"app.worker"
       (worker stop done_ started flushed)
       (fun () ->
         let open Syntax in
         let* () =
           Effect.sync (fun () -> wait_until "worker start" (fun () -> !started))
         in
         let* () = Effect.sync (fun () -> before := !flushed) in
         let* () = Effect.sync (fun () -> Eio.Promise.resolve resolve_stop ()) in
         Effect.sync (fun () -> Eio.Promise.await done_)));
  require "worker still waiting before stop" (not !before);
  require "worker completed after scope exit" !flushed;
  Format.printf "background-shutdown:started=%b before=%b after=%b@." !started
    !before !flushed
