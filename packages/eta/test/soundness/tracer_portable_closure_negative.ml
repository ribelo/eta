let capture_tracer (tracer : Eta.Capabilities.tracer) =
  Eta.Effect.Island.map
    ~f:(fun n ->
      tracer#add_attr ~key:"soundness" ~value:(string_of_int n);
      n)
    [ 1 ]
