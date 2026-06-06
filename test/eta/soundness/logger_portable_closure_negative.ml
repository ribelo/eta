let capture_logger pool (logger : Eta.Capabilities.logger) =
  Eta_par.Island.map ~pool
    ~f:(fun n ->
      logger#log
        {
          Eta.Capabilities.level = Info;
          body = "soundness";
          ts_ms = n;
          attrs = [];
          trace_id = "";
          span_id = "";
        };
      n)
    [ 1 ]
