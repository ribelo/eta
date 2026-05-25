let _ =
  Eta_http_tls.Config.default_client ~version:(`TLS_1_2, `TLS_1_3) ()
