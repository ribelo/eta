(* Prettiest call site — examples/quickstart.ml (new names). *)
open Eta

let program () =
  let open Syntax in
  (let* n =
     Effect.sync (fun () -> Ok (1 + 1))
     |> Effect.flatten_result
   in
   if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.fold ~ok:Fun.id ~error:(function `Too_small -> 3)
