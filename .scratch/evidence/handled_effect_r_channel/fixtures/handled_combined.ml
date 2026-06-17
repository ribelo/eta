type 'a op =
  | Query : string -> int op
  | Info : string -> unit op

module Service = Handled_effect.Make (struct
    type 'a t = 'a op
  end)

let c h id = Service.perform h (Query id)
let b h msg = Service.perform h (Info msg)

let a h id =
  b h ("fetching " ^ id);
  c h id

module type A_SIG = sig
  val a : Service.Handler.t @ local -> string -> int
end

module _ : A_SIG = struct
  let a = a
end

let run ~db ~log f =
  let rec handle = function
    | Service.Value value -> value
    | Service.Exception exn -> raise exn
    | Service.Operation (Query id, continuation) ->
      handle (Handled_effect.continue continuation (Services.query db id) [])
    | Service.Operation (Info msg, continuation) ->
      Services.info log msg;
      handle (Handled_effect.continue continuation () [])
  in
  handle (Service.run f)

let run_db_only ~db f =
  let rec handle = function
    | Service.Value value -> value
    | Service.Exception exn -> raise exn
    | Service.Operation (Query id, continuation) ->
      handle (Handled_effect.continue continuation (Services.query db id) [])
    | Service.Operation (Info _, _) -> failwith "missing log provider"
  in
  handle (Service.run f)
