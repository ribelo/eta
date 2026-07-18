(* DX-E23 red-team probe.
   Deliberately misuse the *new* error-channel name the way the old name invited:
   treat [bind_error] as if it were try/with and try to swallow an exception. *)

open Eta

(* Bug the old name invited: "catch the failure" of a sync leaf that raises. *)
let swallow_exception_via_bind_error =
  Effect.sync (fun () -> failwith "secret-boom")
  |> Effect.bind_error (fun (`Domain : [ `Domain ]) -> Effect.pure "swallowed")

(* Control: typed failure is recoverable. *)
let recover_typed =
  Effect.fail `Domain
  |> Effect.bind_error (fun `Domain -> Effect.pure "recovered")

let pp_error fmt = function
  | `Domain -> Format.pp_print_string fmt "domain"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  (match Eta_eio.Runtime.run rt recover_typed with
  | Exit.Ok "recovered" -> Format.printf "typed:recovered@."
  | Exit.Ok other ->
      Format.eprintf "typed:unexpected ok %S@." other;
      exit 1
  | Exit.Error cause ->
      Format.eprintf "typed:unexpected error %a@." (Cause.pp pp_error) cause;
      exit 1);
  match Eta_eio.Runtime.run rt swallow_exception_via_bind_error with
  | Exit.Ok value ->
      Format.eprintf "FOOTGUN: exception swallowed as %S@." value;
      exit 2
  | Exit.Error (Cause.Die { exn; span_name; annotations; _ }) ->
      Format.printf
        "defect:surfaces Die exn=%s span=%s annotations=%d@."
        (Printexc.to_string exn)
        (match span_name with None -> "-" | Some name -> name)
        (List.length annotations);
      Format.printf "verdict:bind_error did not catch the exception@."
  | Exit.Error cause ->
      Format.eprintf "unexpected non-Die error %a@." (Cause.pp pp_error) cause;
      exit 1
