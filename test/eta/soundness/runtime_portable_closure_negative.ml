let capture_runtime pool rt =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      ignore (Eta.Runtime.run rt (Eta.Effect.pure n));
      n)
    [ 1 ]
