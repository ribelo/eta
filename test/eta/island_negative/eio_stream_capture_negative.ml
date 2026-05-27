let stream = Eio.Stream.create 4

let _ =
  Eta.Effect.Island.map
    ~f:(fun n ->
      Eio.Stream.add stream n;
      n)
    [ 1 ]
