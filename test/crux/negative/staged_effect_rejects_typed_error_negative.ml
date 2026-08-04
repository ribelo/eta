let _machine =
  Eta_crux.State_machine.create (Eta_crux.return ()) ~default_model:0
    ~apply_action:(fun ~self:_ ~input:() ~model ~action:_ ->
      (model, Eta.Effect.fail `Application_error))
