(* Red-team (a): order-sensitive debit/credit transfer written with and*.
   Under sequential and*, the ordered execution log is correct by construction. *)

open Eta

let log = ref []

let mark name =
  Effect.sync (fun () -> log := name :: !log)

let debit amount =
  let open Syntax in
  let* () = mark "debit:start" in
  let* () = mark ("debit:" ^ string_of_int amount) in
  let* () = mark "debit:done" in
  Effect.pure amount

let credit amount =
  let open Syntax in
  let* () = mark "credit:start" in
  let* () = mark ("credit:" ^ string_of_int amount) in
  let* () = mark "credit:done" in
  Effect.pure amount

(* The invited bug under old concurrent and*: interleaving debit/credit.
   With sequential and*, debit fully settles before credit starts. *)
let transfer amount =
  let open Syntax in
  let* debited = debit amount
  and* credited = credit amount in
  Effect.pure (debited, credited)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (transfer 10) with
  | Exit.Ok (10, 10) ->
      let ordered = List.rev !log in
      Format.printf "transfer ok; log=%s@."
        (String.concat " → " ordered);
      let expected =
        [
          "debit:start";
          "debit:10";
          "debit:done";
          "credit:start";
          "credit:10";
          "credit:done";
        ]
      in
      if ordered <> expected then (
        Format.eprintf "expected sequential log, got interleaving@.";
        exit 1);
      Format.printf "VERDICT (a): observably sequential, correct by construction@."
  | Exit.Ok _ ->
      Format.eprintf "unexpected Ok pair@.";
      exit 1
  | Exit.Error cause ->
      Format.eprintf "transfer failed: %a@." (Cause.pp Format.pp_print_string) cause;
      exit 1
