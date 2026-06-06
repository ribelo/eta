let counter = ref 0

let program pool =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      incr counter;
      n)
    [ 1; 2; 3 ]
