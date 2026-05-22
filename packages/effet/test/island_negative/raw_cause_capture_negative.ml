let raw = Effet.Cause.die (Failure "boom")

let _ =
  Effet.Effect.Island.map
    ~f:(fun n ->
      ignore raw;
      n)
    [ 1 ]
