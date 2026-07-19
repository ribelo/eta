(* Review packet — order-sensitive debit/credit transfer with and*.
   Safe shape under sequential Syntax.and*. *)

open Eta

let accounts = Hashtbl.create 4

let get id =
  match Hashtbl.find_opt accounts id with
  | Some bal -> bal
  | None -> 0

let set id bal = Hashtbl.replace accounts id bal

let debit ~from amount =
  Effect.sync (fun () ->
      let bal = get from in
      if bal < amount then failwith "insufficient funds";
      set from (bal - amount);
      amount)

let credit ~into amount =
  Effect.sync (fun () ->
      set into (get into + amount);
      amount)

let transfer ~from ~into amount =
  let open Syntax in
  let* debited = debit ~from amount
  and* credited = credit ~into amount in
  Effect.pure (debited, credited)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  set "alice" 100;
  set "bob" 0;
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (transfer ~from:"alice" ~into:"bob" 40) with
  | Exit.Ok (40, 40) ->
      Format.printf "alice=%d bob=%d@." (get "alice") (get "bob")
  | Exit.Ok _ ->
      Format.eprintf "unexpected pair@.";
      exit 1
  | Exit.Error cause ->
      Format.eprintf "transfer failed: %a@."
        (Cause.pp Format.pp_print_string) cause;
      exit 1
