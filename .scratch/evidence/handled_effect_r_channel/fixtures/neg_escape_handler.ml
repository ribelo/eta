let leaked_db_handler =
  Handled_effect_r_channel.Handled_separate.Db_eff.run (fun db_h -> db_h)

let _ = leaked_db_handler
