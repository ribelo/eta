module S = Handled_effect_r_channel.Services
module H = Handled_effect_r_channel.Handled_separate

let broken_run ~db ~log f =
  let rec handle_log = function
    | H.Log_eff.Value value -> value
    | H.Log_eff.Exception exn -> raise exn
    | H.Log_eff.Operation (H.Info msg, continuation) ->
      S.info log msg;
      handle_log (Handled_effect.continue continuation () [])
  in
  handle_log
    (H.Log_eff.run (fun log_h ->
       let rec handle_db = function
         | H.Db_eff.Value value -> value
         | H.Db_eff.Exception exn -> raise exn
         | H.Db_eff.Operation (H.Query id, continuation) ->
           handle_db (Handled_effect.continue continuation (S.query db id) [])
       in
       handle_db (H.Db_eff.run_with [ log_h ] (fun [ db_h; log_h ] -> f db_h log_h))))

let _ = broken_run
