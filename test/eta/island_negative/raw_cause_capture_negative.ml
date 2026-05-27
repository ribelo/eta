let raw = Eta.Cause.die (Failure "boom")

let _ =
  Eta.Effect.Island.map
    ~f:(fun n ->
      ignore raw;
      n)
    [ 1 ]
