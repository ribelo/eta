let logger = Eta.Logger.in_memory ()

let program pool =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      ignore (Eta.Logger.dump logger);
      n)
    [ 1 ]
