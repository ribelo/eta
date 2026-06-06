let capture_runtime rt =
  Eta.Island.map
    ~f:(fun n ->
      ignore (Eta.Runtime.run rt (Eta.Effect.pure n));
      n)
    [ 1 ]
