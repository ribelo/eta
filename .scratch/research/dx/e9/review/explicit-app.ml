(* Program that WANTS sequencing: order-sensitive ledger writes.
   open Syntax + open Syntax.Applicative declares left-then-right product. *)

open Eta

type error = [ `Insufficient of string | `Unknown_account of string ]

(* Sketch of ordered domain writes — debit must settle before credit. *)
let write_balance account f =
  Effect.sync_result (fun () ->
      match account with
      | "" -> Error (`Unknown_account account)
      | _ -> Ok (f 100))

let transfer ~debit ~credit ~amount =
  let open Syntax in
  let open Syntax.Applicative in
  let* debit_bal = write_balance debit (fun bal -> bal - amount)
  and* credit_bal = write_balance credit (fun bal -> bal + amount) in
  Effect.pure (debit_bal, credit_bal)
