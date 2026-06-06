let raw = Eta.Cause.die (Failure "boom")

let _ =
  Eta.Island.map
    ~f:(fun n ->
      ignore raw;
      n)
    [ 1 ]
