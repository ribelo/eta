let capture_meter pool (meter : Eta.Capabilities.meter) =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      meter#record ~name:"soundness" ~description:"" ~unit_:"1"
        ~kind:Eta.Capabilities.Counter_cumulative ~attrs:[]
        ~value:(Eta.Capabilities.Int n) ~ts_ms:n;
      n)
    [ 1 ]
