open Eta

type error = [ `Refresh_failed ]

let program =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* _child = start sup (fail `Refresh_failed) in
        let* () = yield in
        let* failures = failures sup in
        pure (List.length failures);
  }

let pp_error fmt = function
  | `Refresh_failed -> Format.pp_print_string fmt "refresh-failed"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok count -> Format.printf "supervisor:failures:%d@." count
  | Exit.Error cause ->
      Format.eprintf "supervisor failed: %a@." (Cause.pp pp_error) cause;
      exit 1
