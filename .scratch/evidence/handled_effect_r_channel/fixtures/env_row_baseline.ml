module Effect = struct
  type ('env, 'a) t = 'env -> 'a

  let pure v _env = v
  let sync f env = f env
  let bind e f env = f (e env) env
  let ( let* ) e f = bind e f
  let run env e = e env
end

let c id : (< db : Services.db; .. >, int) Effect.t =
  Effect.sync (fun env -> Services.query env#db id)

let b msg : (< log : Services.log; .. >, unit) Effect.t =
  Effect.sync (fun env -> Services.info env#log msg)

let a id =
  let open Effect in
  let* () = b ("fetching " ^ id) in
  c id

module type A_SIG = sig
  val a : string -> (< db : Services.db; log : Services.log; .. >, int) Effect.t
end

module _ : A_SIG = struct
  let a = a
end

let boot ~db ~log id =
  let env =
    object
      method db = db
      method log = log
    end
  in
  Effect.run env (a id)
