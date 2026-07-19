open Eta

type user = { id : string; name : string }
type error = [ `Missing_user of string ]
[@@deriving eta_error]

let lookup_user id =
  if String.equal id "" then Error (`Missing_user id)
  else Ok { id; name = "user:" ^ id }

let load_user id =
  Effect.sync_result (fun () -> lookup_user id)

let render_user user =
  user.id ^ ":" ^ user.name

let settled_counts outcomes =
  List.fold_left
    (fun (ok, missing) -> function
      | Ok _ -> (ok + 1, missing)
      | Error (Cause.Fail (`Missing_user _)) -> (ok, missing + 1)
      | Error _ -> (ok, missing))
    (0, 0) outcomes

let program =
  let open Syntax in
  let* loaded =
    Effect.map_par ~max_concurrent:2 load_user [ "alpha"; "beta"; "gamma" ]
  in
  let+ outcomes =
    [ "ok"; ""; "still-ok" ] |> List.map load_user |> Effect.all_settled
  in
  (List.map render_user loaded, settled_counts outcomes)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok (loaded, (ok_count, missing_count)) ->
      Format.printf "batch:%s settled=%d/%d@."
        (String.concat "," loaded)
        ok_count missing_count
  | Exit.Error cause ->
      Format.eprintf "batch failed: %a@." (Cause.pp pp_error) cause;
      exit 1
