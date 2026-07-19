(* Red-team fix under the new shape: the open declares sequential product.
   Same transfer as implicit_race.ml, but Syntax.Applicative guarantees
   left settles before right starts; nothing is forked. *)

let transfer_sequential ~debit ~credit ~amount =
  let open Eta.Syntax in
  let open Eta.Syntax.Applicative in
  (* Open declares: left-to-right product, fail-fast by sequencing. *)
  let* () = Db.write debit (fun bal -> bal - amount)
  and* () = Db.write credit (fun bal -> bal + amount) in
  Effect.pure ()

(* Guarantees vs implicit_race.ml:
   - credit write does not start until debit write succeeds
   - debit failure skips credit entirely
   - no sibling fiber to cancel mid-write on the other side
*)

let transfer_if_truly_concurrent ~debit ~credit ~amount =
  let open Eta.Syntax in
  let open Eta.Syntax.Parallel in
  (* Only correct when the domain truly tolerates concurrent independent writes. *)
  let* () = Db.write debit (fun bal -> bal - amount)
  and* () = Db.write credit (fun bal -> bal + amount) in
  Effect.pure ()
