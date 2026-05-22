let program rt =
  Effet.Effect.Island.map
    ~f:(fun n ->
      ignore (Effet.Runtime.run rt (Effet.Effect.pure n));
      n)
    [ 1 ]
