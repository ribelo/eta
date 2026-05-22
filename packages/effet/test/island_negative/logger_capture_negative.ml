let logger = Effet.Logger.in_memory ()

let _ =
  Effet.Effect.Island.map
    ~f:(fun n ->
      ignore (Effet.Logger.dump logger);
      n)
    [ 1 ]
