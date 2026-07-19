(* Wrong-under-old-shape twin of explicit-app.ml.
   Same order-sensitive transfer written with always-open Syntax and*.
   Under pre-split Syntax this silently used Effect.par (race).
   Kept as the baseline race form for blinded comparison. *)

open Eta

type error = [ `Insufficient of string | `Unknown_account of string ]

let write_balance account f =
  Effect.sync_result (fun () ->
      match account with
      | "" -> Error (`Unknown_account account)
      | _ -> Ok (f 100))

let transfer ~debit ~credit ~amount =
  let open Syntax in
  (* No Parallel/Applicative open — old always-open product. *)
  let* debit_bal = write_balance debit (fun bal -> bal - amount)
  and* credit_bal = write_balance credit (fun bal -> bal + amount) in
  Effect.pure (debit_bal, credit_bal)
