open Eta

let snapshot name eff =
  Printf.printf "===== %s =====\n%s\n" name (Effect.describe eff)

let () =
  snapshot "pure-map-chain"
    (Effect.pure 1 |> Effect.map (( + ) 1) |> Effect.map string_of_int);
  snapshot "named-leaf" (Effect.named "user.load" (Effect.sync (fun () -> ())));
  snapshot "nested-bind"
    (Effect.unit
    |> Effect.bind (fun () -> Effect.unit)
    |> Effect.bind (fun () -> Effect.unit));
  snapshot "par"
    (Effect.par (Effect.pure ()) (Effect.fail "right") |> Effect.discard);
  snapshot "all" (Effect.all [ Effect.pure (); Effect.fail "right" ]);
  snapshot "race" (Effect.race [ Effect.pure (); Effect.fail "right" ]);
  snapshot "map-par" (Effect.map_par (fun value -> Effect.pure value) [ () ]);
  snapshot "fold"
    (Effect.fold ~ok:(fun () -> ()) ~error:(fun (_ : string) -> ())
       (Effect.fail "failed"));
  snapshot "bind-error"
    (Effect.bind_error (fun (_ : string) -> Effect.unit) (Effect.fail "failed"));
  snapshot "resource"
    (Effect.with_resource ~acquire:(Effect.pure ())
       ~release:(fun () -> Effect.unit) (fun () -> Effect.unit));
  snapshot "background" (Effect.daemon Effect.unit)
