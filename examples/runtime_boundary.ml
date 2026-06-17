open Eta

type error = [ `Rejected of string ]

let ok_program : (string, error) Effect.t =
  Effect.pure "ready"

let rejected_program : (string, error) Effect.t =
  Effect.fail (`Rejected "quota")

let run_preserving_exit rt =
  match Eta_eio.Runtime.run rt rejected_program with
  | Exit.Error (Cause.Fail (`Rejected reason)) -> "exit:" ^ reason
  | exit ->
      Format.eprintf "runtime boundary produced unexpected exit: %a@."
        (Exit.pp Format.pp_print_string (fun fmt (`Rejected reason) ->
             Format.fprintf fmt "rejected:%s" reason))
        exit;
      Stdlib.exit 1

let run_collapsing_exn rt =
  try
    ignore (Eta_eio.Runtime.run_exn rt rejected_program);
    "not-raised"
  with Failure _ -> "raised"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ok = Eta_eio.Runtime.run_exn rt ok_program in
  let preserved = run_preserving_exit rt in
  let collapsed = run_collapsing_exn rt in
  Format.printf "runtime-boundary:run=%s run_exn_ok=%s run_exn_error=%s@."
    preserved ok collapsed
