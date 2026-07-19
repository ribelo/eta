(* Red-team: the bug the OLD always-open Syntax invited.
   Author believes and* is sequential product (order-sensitive DB writes).
   Under old `let open Syntax in`, and* = Effect.par — silent race.

   This file is the "wrong under old shape" twin. It is intentionally the
   implicit form: nothing at the open site declares concurrency. *)

(* Domain sketch (not linked into the main dune workspace): *)

let transfer_wrong ~debit ~credit ~amount =
  let open Eta.Syntax in
  (* Author intent: debit first, then credit. Actual old semantics: both fork. *)
  let* () = Db.write debit (fun bal -> bal - amount)
  and* () = Db.write credit (fun bal -> bal + amount) in
  Effect.pure ()

(* Failure mode:
   - If debit fails after credit has already written, money is created.
   - If both run, ledger order is nondeterministic.
   - Sibling cancel on debit failure may leave credit half-applied depending on
     timing — not the sequential "all or nothing by bind order" the author
     expected.
*)
