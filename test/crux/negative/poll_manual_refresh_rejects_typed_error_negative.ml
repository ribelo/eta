let _poll =
  Eta_crux.Poll.manual_refresh
    ~starting:Eta_crux.Poll.Starting.empty
    ~effect:
      (Eta_crux.return
         (Eta.Effect.fail `Application_error))
    ()
