let authenticator =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let _ =
  Eta_http_tls.Config.default_client ~authenticator
    ~ciphers:[ `DHE_RSA_WITH_AES_128_GCM_SHA256 ] ()
