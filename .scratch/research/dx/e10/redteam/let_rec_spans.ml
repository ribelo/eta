(* Red-team fixture: let%eta rec should re-enter Effect.fn per call.
   Runtime evidence is the Alcotest case
   "let%eta rec per-call spans" in test/ppx_common/ppx_common_suites.ml
   (expects 4 spans for countdown 3). *)
open Eta

let%eta rec countdown n =
  if n <= 0 then Effect.pure 0
  else
    let open Syntax in
    let* _ = Effect.pure () in
    countdown (n - 1)

let () = ignore countdown
