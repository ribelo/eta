(* Archaeology E: return a pool-borrowed connection from Pool.with_resource.
   Predicted: COMPILES (no phantom; the conn is released back to the pool and
   the escaped reference aliases whatever the next borrower gets). *)
open Eta

let program pool =
  Pool.with_resource pool (fun conn -> Effect.pure conn)
