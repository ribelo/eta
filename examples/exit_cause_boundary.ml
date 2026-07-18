open Eta

type error =
  [ `Close_failed
  | `Rejected of string ]

let render_error = function
  | `Close_failed -> "close-failed"
  | `Rejected reason -> "rejected:" ^ reason

let pp_error fmt err =
  Format.pp_print_string fmt (render_error err)

let typed_program : (string, error) Effect.t =
  Effect.fail (`Rejected "bad input")

let defect_program : (string, error) Effect.t =
  Effect.named "decode"
    (Effect.sync (fun () -> failwith "decoder exploded"))

let cleanup_program : (string, error) Effect.t =
  Effect.with_error_pp pp_error
    (Effect.with_resource ~acquire:(Effect.pure "handle")
       ~release:(fun _ -> Effect.fail `Close_failed)
       (fun handle -> Effect.pure handle))

let unexpected label exit_value =
  Format.eprintf "%s produced unexpected exit: %a@." label
    (Exit.pp Format.pp_print_string pp_error)
    exit_value;
  Stdlib.exit 1

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let typed_exit = Eta_eio.Runtime.run rt typed_program in
  let defect_exit = Eta_eio.Runtime.run rt defect_program in
  let cleanup_exit = Eta_eio.Runtime.run rt cleanup_program in
  let typed =
    match Exit.to_result typed_exit with
    | Some (Error (`Rejected reason)) -> "result:" ^ reason
    | _ -> unexpected "typed failure" typed_exit
  in
  let defect =
    match (defect_exit, Exit.to_result defect_exit) with
    | Exit.Error (Cause.Die _), None -> "die"
    | _ -> unexpected "defect" defect_exit
  in
  let finalizer =
    match (cleanup_exit, Exit.to_result cleanup_exit) with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail reason)), None -> reason
    | _ -> unexpected "cleanup failure" cleanup_exit
  in
  Format.printf "exit-cause:typed=%s defect=%s finalizer=%s@." typed defect
    finalizer
