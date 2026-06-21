let capture_meter pool (meter : Eta.Capabilities.meter) =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      meter#record
        {
          Eta.Meter.name = "soundness";
          description = "";
          unit_ = "1";
          kind = Eta.Capabilities.Counter { monotonic = false };
          attrs = [];
          value = Eta.Capabilities.Number (Eta.Capabilities.Int n);
          ts_ms = n;
        };
      n)
    [ 1 ]
