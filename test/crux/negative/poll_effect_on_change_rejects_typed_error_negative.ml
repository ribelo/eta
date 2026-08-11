let _poll =
  Eta_crux.Poll.effect_on_change
    ~input_cutoff:Eta_crux.Cutoff.phys_equal
    ~starting:Eta_crux.Poll.Starting.empty
    ~input:(Eta_crux.return ())
    ~effect:
      (Eta_crux.return (fun () ->
           Eta.Effect.fail `Application_error))
    ()
