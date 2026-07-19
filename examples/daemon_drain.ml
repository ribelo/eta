open Eta

type error = [ `Unexpected ] [@@deriving eta_error]

let require label condition =
  if not condition then failwith ("daemon drain check failed: " ^ label)

let wait_until label f =
  let rec loop attempts =
    if f () then ()
    else if attempts = 0 then failwith ("timed out waiting for " ^ label)
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 1_000

let daemon release started completed =
  let open Syntax in
  Effect.named ~error_pp:pp_error "daemon.flush"
    (let* () = Effect.sync (fun () -> started := true) in
     let* () = Effect.sync (fun () -> Eio.Promise.await release) in
     Effect.sync (fun () -> completed := true))

let run_ok rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Format.eprintf "daemon drain failed: %a@." (Cause.pp pp_error) cause;
      exit 1

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let release, resolve_release = Eio.Promise.create () in
  let started = ref false in
  let completed = ref false in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  run_ok rt (Effect.daemon (daemon release started completed));
  wait_until "daemon start" (fun () -> !started);
  let before_drain = !completed in
  require "daemon still waiting before drain" (not before_drain);
  Eio.Promise.resolve resolve_release ();
  Eta_eio.Runtime.drain rt;
  require "daemon completed after drain" !completed;
  Format.printf "daemon-drain:started=%b before=%b after=%b@." !started
    before_drain !completed
