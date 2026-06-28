(* Predicted error:
   Public_mli_styles.closed_row_value requires the exact closed row
   < clock; log >. Running it with an env that also has secret must fail,
   showing why closed rows are compact but poor public capability style. *)

open R_followup_research

let _ =
  let log = Services.log () in
  let env =
    object
      method clock = Services.clock 1
      method log = log
      method secret = Services.secret "s3"
    end
  in
  Services.run_with_env env Public_mli_styles.closed_row_value
