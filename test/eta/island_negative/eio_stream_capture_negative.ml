let stream = Eio.Stream.create 4

let _ =
  Eta.Island.map
    ~f:(fun n ->
      Eio.Stream.add stream n;
      n)
    [ 1 ]
