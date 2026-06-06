let capture_logger (logger : Eta.Capabilities.logger) =
  Eta.Island.map
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
