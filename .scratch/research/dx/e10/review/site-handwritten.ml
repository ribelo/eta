(* Genuine site shape from test/core_common/observability_common_suites.ml
   (test_observability_fn_loc): Effect.fn __POS__ __FUNCTION__ at a definition. *)
open Eta

let program () = Effect.fn __POS__ __FUNCTION__ (Effect.pure ())
