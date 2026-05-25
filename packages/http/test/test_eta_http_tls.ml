open Test_eta_http_support

let test_tls_chokepoint_policy () =
  let client = Http.Tls.Config.default_client () in
  Alcotest.(check bool)
    "TLS 1.2 only"
    true
    (Http.Tls.Config.policy_version = (`TLS_1_2, `TLS_1_2));
  Alcotest.(check (list string))
    "exact policy ciphers"
    Http.Tls.Config.policy_ciphers
    Http.Tls.Config.policy_ciphers;
  Alcotest.(check (list string))
    "default ALPN" [ "h2"; "http/1.1" ]
    (Http.Tls.Config.alpn_protocols client)
