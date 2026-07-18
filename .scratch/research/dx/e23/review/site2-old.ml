(* Prettiest call site — examples/quickstart.ml (old names). *)
open Eta

let program () =
  let open Syntax in
  (let* n =
     Effect.sync (fun () -> Ok (1 + 1))
     |> Effect.flatten_result
   in
   if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.recover (function `Too_small -> 3)
