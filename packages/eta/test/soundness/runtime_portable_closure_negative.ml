let capture_runtime rt =
  Eta.Effect.Island.map
    ~f:(fun n ->
      ignore (Eta.Runtime.run rt (Eta.Effect.pure n));
      n)
    [ 1 ]
