let capture_tracer pool (tracer : Eta.Capabilities.tracer) =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      tracer#add_attr (Obj.magic ()) ~key:"soundness" ~value:(string_of_int n);
      n)
    [ 1 ]
