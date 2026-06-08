let attack =
  let open Malicious_server in
  {
    id = "ping_flood";
    group = Q5;
    title = "PING flood";
    falsifier =
      "Server PING frames faster than the ACK policy must be dropped by disconnect without fd/fiber leaks.";
    coverage = H_d1_multiplexer;
    default =
      default ~knob:"max_ping_per_second" ~value:"100/sec"
        ~justification:
          "HTTP/2 PING is diagnostic, not data. 100/sec is already far above health-check usage and below the 1000/sec attack fixture."
        ~error_variant:"Ping_rate_exceeded";
    expected_error_class = "ping_rate_exceeded";
    frames_per_second = 1000;
  }
