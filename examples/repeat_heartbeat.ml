open Eta

let heartbeat ticks =
  Effect.repeat (Schedule.recurs 3)
    (Effect.sync (fun () -> ticks := !ticks + 1))

let pp_never fmt = function _ -> Format.pp_print_string fmt "<never>"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let ticks = ref 0 in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (heartbeat ticks) with
  | Exit.Ok _ ->
      if !ticks <> 4 then
        failwith
          (Printf.sprintf "repeat heartbeat expected 4 ticks, got %d" !ticks);
      Format.printf "repeat-heartbeat:ticks=%d policy=recurs:3@." !ticks
  | Exit.Error cause ->
      Format.eprintf "repeat heartbeat failed: %a@." (Cause.pp pp_never) cause;
      exit 1
