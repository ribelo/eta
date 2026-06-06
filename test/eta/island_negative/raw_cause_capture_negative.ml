let raw = Eta.Cause.die (Failure "boom")

let program pool =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      ignore raw;
      n)
    [ 1 ]
