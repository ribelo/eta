let counter = ref 0

let _ =
  Effet.Effect.Island.map
    ~f:(fun n ->
      incr counter;
      n)
    [ 1; 2; 3 ]
