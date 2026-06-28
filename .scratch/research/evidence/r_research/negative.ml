(* Negative tests: each must fail to compile.
   Run with: dune build scratch/r_research/negative.ml 2>&1
   Toggle BREAK to enable each. *)

(* ===== Negative test 1: R-A explicit cannot define A without args ===== *)
[%%if false]
module R_a_no_args = struct
  module E = R_research.R_a_explicit.Effect
  open R_research.R_a_explicit

  (* Must fail: b and c demand ~db / ~log. *)
  let _a id =
    let open E in
    let* () = b (Printf.sprintf "fetching %s" id) in
    c id
end
[%%endif]

(* ===== Negative test 2: R-A composite cannot define A without `s` ===== *)
[%%if false]
module R_a_composite_no_arg = struct
  module E = R_research.R_a_composite.Effect
  open R_research.R_a_composite

  let _a id =
    let open E in
    let* () = b (Printf.sprintf "fetching %s" id) in
    c id
end
[%%endif]

(* ===== Negative test 3: R-B with missing service at boot ===== *)
[%%if false]
module R_b_missing_db = struct
  open R_research.R_b_env_row
  let _ =
    let env = object method log = Services.log_of (Services.Log.make "x") end in
    Effect.run env (a "42")
end
[%%endif]

let () = ()
