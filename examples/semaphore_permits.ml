open Eta

type error = [ `Rejected of string ]

let inside sem label =
  Semaphore.with_permits sem 1 (fun () ->
      Effect.sync (fun () ->
          if String.equal label "" then Error (`Rejected "empty label")
          else
            Ok
              (Printf.sprintf "%s:available=%d" label
                 (Semaphore.available sem)))
      |> Effect.flatten_result)

let rejected sem =
  Semaphore.with_permits sem 1 (fun () -> Effect.fail (`Rejected "boom"))
  |> Effect.fold ~ok:Fun.id ~error:(fun (`Rejected reason) -> "failed:" ^ reason)

let program sem =
  let open Syntax in
  let* first = inside sem "alpha" in
  let* failed = rejected sem in
  let available = Semaphore.available sem in
  let waiting = Semaphore.waiting sem in
  (first, failed, available, waiting)
  |> Effect.pure

let pp_error fmt = function
  | `Rejected reason -> Format.fprintf fmt "rejected:%s" reason

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let sem = Semaphore.make ~permits:1 in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program sem) with
  | Exit.Ok (first, failed, available, waiting) -> (
      match (first, failed, available, waiting) with
      | "alpha:available=0", "failed:boom", 1, 0 ->
          Format.printf "semaphore-permits:first=%s failed=%s available=%d waiting=%d@."
            first failed available waiting
      | _ ->
          Format.eprintf "semaphore permits produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "semaphore permits failed: %a@." (Cause.pp pp_error) cause;
      exit 1
