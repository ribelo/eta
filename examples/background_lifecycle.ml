open Eta

type error = [ `Missing_user of string ]

let background started stopped =
  let open Syntax in
  let* () =
    Effect.acquire_release
      ~acquire:(Effect.sync (fun () -> started := true))
      ~release:(fun () -> Effect.sync (fun () -> stopped := true))
  in
  Effect.yield

let wait_started started =
  Effect.sync (fun () ->
      let rec loop attempts =
        if !started then ()
        else if attempts = 0 then failwith "background did not start"
        else (
          Eio.Fiber.yield ();
          loop (attempts - 1))
      in
      loop 1_000)

let load_user id =
  Effect.sync_result (fun () ->
      if String.equal id "" then Error (`Missing_user id)
      else Ok ("user:" ^ id))

let program started stopped =
  let open Syntax in
  Effect.with_background ~name:"cache.refresh" (background started stopped)
    (fun () ->
      let* () = wait_started started in
      let* left = Effect.named "load.left" (load_user "left")
      and* right = Effect.named "load.right" (load_user "right") in
      Effect.pure (left, right))

let pp_error fmt = function
  | `Missing_user id -> Format.fprintf fmt "missing-user:%s" id

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let started = ref false in
  let stopped = ref false in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program started stopped) with
  | Exit.Ok (left, right) ->
      if not !stopped then (
        Format.eprintf "background finalizer did not run@.";
        exit 1);
      Format.printf "background:%s,%s stopped=%b@." left right !stopped
  | Exit.Error cause ->
      Format.eprintf "background failed: %a@." (Cause.pp pp_error) cause;
      exit 1
