let stream = Eio.Stream.create 4

let program pool =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      Eio.Stream.add stream n;
      n)
    [ 1 ]
