open Test_eta_http_support

let same_cipher_set left right =
  List.length left = List.length right
  && List.for_all (fun cipher -> List.mem cipher right) left

let reject_if_dhe cipher =
  match Tls.Ciphersuite.ciphersuite_kex cipher with `FFDHE -> false | _ -> true

let test_tls_chokepoint_policy () =
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg msg) -> Alcotest.fail msg
  in
  let client = Eta_http.Tls.Config.default_client ~authenticator () in
  let config = Tls.Config.of_client client in
  Alcotest.(check bool)
    "TLS 1.2 only"
    true
    (config.Tls.Config.protocol_versions = Eta_http.Tls.Config.policy_version);
  Alcotest.(check bool)
    "exact policy ciphers"
    true
    (same_cipher_set config.ciphers Eta_http.Tls.Config.policy_ciphers);
  Alcotest.(check bool)
    "no DHE"
    true
    (List.for_all reject_if_dhe config.ciphers);
  Alcotest.(check int) "no TLS 1.3 ciphers" 0
    (List.length (Tls.Config.ciphers13 config));
  Alcotest.(check (list string))
    "default ALPN" [ "h2"; "http/1.1" ] config.alpn_protocols


