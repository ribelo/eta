open Eta

type error = [ `Rejected of string ]
[@@deriving eta_error]

let admit ?(abort = Effect.delay (Duration.ms 10) Effect.unit) sem label =
  let open Syntax in
  let+ result =
    Semaphore.with_permits_or_abort sem 1 ~abort (fun () ->
        Effect.sync_result (fun () ->
            if String.equal label "" then Error (`Rejected "empty label")
            else
              Ok
                (Printf.sprintf "accepted:%s:available=%d" label
                   (Semaphore.available sem))))
  in
  match result with
  | Some accepted -> accepted
  | None -> "busy:" ^ label

let program sem =
  let open Syntax in
  let* first = admit sem "alpha" in
  let* second =
    Semaphore.with_permits sem 1 (fun () ->
        admit ~abort:Effect.unit sem "beta")
  in
  let available = Semaphore.available sem in
  let waiting = Semaphore.waiting sem in
  (first, second, available, waiting)
  |> Effect.pure

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let sem = Semaphore.make ~permits:1 in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program sem) with
  | Exit.Ok (first, second, available, waiting) ->
      Format.printf "admission:%s,%s available=%d waiting=%d@." first second
        available waiting
  | Exit.Error cause ->
      Format.eprintf "admission failed: %a@." (Cause.pp pp_error) cause;
      exit 1
