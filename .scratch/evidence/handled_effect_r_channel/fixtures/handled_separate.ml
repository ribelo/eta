type 'a db_op = Query : string -> int db_op
type 'a log_op = Info : string -> unit log_op

module Db_eff = Handled_effect.Make (struct
    type 'a t = 'a db_op
  end)

module Log_eff = Handled_effect.Make (struct
    type 'a t = 'a log_op
  end)

let c db_h id = Db_eff.perform db_h (Query id)
let b log_h msg = Log_eff.perform log_h (Info msg)

let a db_h log_h id =
  b log_h ("fetching " ^ id);
  c db_h id

module type A_SIG = sig
  val a : Db_eff.Handler.t @ local -> Log_eff.Handler.t @ local -> string -> int
end

module _ : A_SIG = struct
  let a = a
end

let run ~db ~log f =
  let rec handle_log = function
    | Log_eff.Value value -> value
    | Log_eff.Exception exn -> raise exn
    | Log_eff.Operation (Info msg, continuation) ->
      Services.info log msg;
      handle_log (Handled_effect.continue continuation () [])
  in
  handle_log
    (Log_eff.run (fun log_h ->
       let rec handle_db = function
         | Db_eff.Value value -> value
         | Db_eff.Exception exn -> raise exn
         | Db_eff.Operation (Query id, continuation) ->
           handle_db
             (Handled_effect.continue continuation (Services.query db id) [ log_h ])
       in
       (handle_db
          (Db_eff.run_with [ log_h ] (fun [ db_h; log_h ] -> f db_h log_h))
        [@nontail])))
