open Test_eta_http_support

let test_tls_chokepoint_policy () =
  let client = Eta_http.Tls.Config.default_client () in
  Alcotest.(check bool)
    "TLS 1.2 only"
    true
    (Eta_http.Tls.Config.policy_version = (`TLS_1_2, `TLS_1_2));
  Alcotest.(check (list string))
    "exact policy ciphers"
    Eta_http.Tls.Config.policy_ciphers
    Eta_http.Tls.Config.policy_ciphers;
  Alcotest.(check (list string))
    "default ALPN" [ "h2"; "http/1.1" ]
    (Eta_http.Tls.Config.alpn_protocols client)

let test_openssl_ssl_finalizer_keeps_ctx_ownership_separate () =
  let exercise_shared_ctx () =
    let ctx = Eta_http__Openssl.create_ctx () in
    let ssl_a = Eta_http__Openssl.create_ssl ctx ~hostname:None ~alpn_protocols:[] in
    let ssl_b = Eta_http__Openssl.create_ssl ctx ~hostname:None ~alpn_protocols:[] in
    Gc.full_major ();
    Alcotest.(check int)
      "pending bytes before handshake" 0
      (Eta_http__Openssl.bio_write_pending ssl_a);
    ignore (Eta_http__Openssl.bio_write_pending ssl_b : int)
  in
  exercise_shared_ctx ();
  Gc.full_major ();
  Gc.full_major ()
