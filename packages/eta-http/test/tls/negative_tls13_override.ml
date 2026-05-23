let authenticator =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let _ =
  Eta_http_tls.Config.default_client ~authenticator
    ~version:(`TLS_1_2, `TLS_1_3) ()
