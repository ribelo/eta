(** [Eta_http_service_eio.Serve] — operator piece (public API sketch).

    Thin readiness-gate + SIGTERM->graceful-drain wrapper over
    [Eta_http_eio.Server.run_h1] / [run_h2c]. Owns the lifecycle invariant
    (readiness flips false BEFORE the drain starts); owns NO application state.
    See [docs/research/eta-http-service-api.md] and [.scratch .../p4_operator.md]. *)

val h1 :
  ?port:int ->
  ?config:Eta_http_eio.Server.Config.t ->
  handler:Eta_http.Server.handler ->
  unit -> unit

val h2c :
  ?port:int ->
  ?config:Eta_http_eio.Server.Config.t ->
  handler:Eta_http.Server.handler ->
  unit -> unit
