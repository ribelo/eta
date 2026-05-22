let logger = Eta.Logger.in_memory ()

let _ =
  Eta.Effect.Island.map
    ~f:(fun n ->
      ignore (Eta.Logger.dump logger);
      n)
    [ 1 ]
