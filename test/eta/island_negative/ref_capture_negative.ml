let counter = ref 0

let _ =
  Eta.Island.map
    ~f:(fun n ->
      incr counter;
      n)
    [ 1; 2; 3 ]
