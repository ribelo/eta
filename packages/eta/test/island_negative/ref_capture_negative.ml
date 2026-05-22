let counter = ref 0

let _ =
  Eta.Effect.Island.map
    ~f:(fun n ->
      incr counter;
      n)
    [ 1; 2; 3 ]
