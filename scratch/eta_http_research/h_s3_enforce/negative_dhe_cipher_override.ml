let authenticator =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let _ =
  H_s3_enforce_policy.Default_config_builder.default_client ~authenticator
    ~ciphers:[ `DHE_RSA_WITH_AES_128_GCM_SHA256 ] ()
