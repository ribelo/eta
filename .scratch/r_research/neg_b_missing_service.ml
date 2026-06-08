(* NEGATIVE TEST: R-B env row. Boot with env missing `db`.
   Expected: COMPILE FAILURE — env doesn't satisfy <db : ..; log : ..>. *)
open R_b_env_row

let _bad_boot () =
  let env = object method log = Services.log_of (Services.Log.make "x") end in
  Effect.run env (a "42")
