(* F-C: Hybrid. Default surface is collection combinators (par/all);
   opt-in Fiber.t lives inside a [scoped] block whose body is
   universally quantified over a phantom scope tag, preventing the
   fiber from escaping (ST-monad trick). *)

module Effect = struct
  (* Outer effect: no scope tag. *)
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Sync : ('env -> 'a) -> ('env, _, 'a) t
    | Bind : ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Par  : ('env, 'err, 'a) t * ('env, 'err, 'b) t
        -> ('env, 'err, 'a * 'b) t
    | All  : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
    | Scoped : ('env, 'err, 'a) scoped_body -> ('env, 'err, 'a) t

  (* Inner effect: carries a scope tag 's so fibers cannot escape. *)
  and ('s, 'env, 'err, 'a) scoped_t =
    | S_pure : 'a -> (_, _, _, 'a) scoped_t
    | S_lift : ('env, 'err, 'a) t -> (_, 'env, 'err, 'a) scoped_t
    | S_bind : ('s, 'env, 'err, 'b) scoped_t
        * ('b -> ('s, 'env, 'err, 'a) scoped_t)
        -> ('s, 'env, 'err, 'a) scoped_t
    | S_fork : ('s, 'env, 'err, 'a) scoped_t
        -> ('s, 'env, _, ('s, 'err, 'a) fiber) scoped_t
    | S_await : ('s, 'err, 'a) fiber -> ('s, _, 'err, 'a) scoped_t
    | S_interrupt : ('s, _, 'a) fiber -> ('s, _, _, unit) scoped_t

  (* Fiber tagged with the scope it was forked in. *)
  and ('s, 'err, 'a) fiber = {
    promise : ('a, 'err) result Eio.Promise.t;
    cancel  : unit -> unit;
  }

  (* Rank-2 trick: scoped_body wraps a function polymorphic in 's. *)
  and ('env, 'err, 'a) scoped_body = {
    run : 's. unit -> ('s, 'env, 'err, 'a) scoped_t
  }

  (* Outer constructors. *)
  let pure v = Pure v
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let fail e = Fail e
  let par a b = Par (a, b)
  let all xs = All xs

  (* The escape hatch: pass a body record polymorphic in 's. *)
  let scoped body = Scoped body

  (* Inner constructors. *)
  let s_lift e = S_lift e
  let s_pure v = S_pure v
  let s_bind k e = S_bind (e, k)
  let ( let** ) e k = S_bind (e, k)
  let fork e = S_fork e
  let await f = S_await f
  let interrupt f = S_interrupt f

  (* Interpreter (sketch; runtime correctness is not the lab's question). *)
  let rec interpret : type env err a.
      env:env -> sw:Eio.Switch.t -> (env, err, a) t -> (a, err) result =
   fun ~env ~sw eff ->
    match eff with
    | Pure v -> Ok v
    | Sync f -> Ok (f env)
    | Fail e -> Error e
    | Bind (e, k) -> (
        match interpret ~env ~sw e with
        | Error e -> Error e
        | Ok v -> interpret ~env ~sw (k v))
    | Par (a, b) ->
        (* simplified *)
        (match interpret ~env ~sw a with
         | Error e -> Error e
         | Ok va ->
             match interpret ~env ~sw b with
             | Error e -> Error e
             | Ok vb -> Ok (va, vb))
    | All xs ->
        let rec go = function
          | [] -> Ok []
          | x :: rest ->
              match interpret ~env ~sw x with
              | Error e -> Error e
              | Ok v -> match go rest with
                | Error e -> Error e
                | Ok vs -> Ok (v :: vs)
        in
        go xs
    | Scoped body ->
        Eio.Switch.run @@ fun child_sw ->
        interpret_scoped ~env ~sw:child_sw (body.run ())

  and interpret_scoped : type s env err a.
      env:env -> sw:Eio.Switch.t -> (s, env, err, a) scoped_t -> (a, err) result =
   fun ~env ~sw eff ->
    match eff with
    | S_pure v -> Ok v
    | S_lift e -> interpret ~env ~sw e
    | S_bind (e, k) -> (
        match interpret_scoped ~env ~sw e with
        | Error e -> Error e
        | Ok v -> interpret_scoped ~env ~sw (k v))
    | S_fork child ->
        let promise, resolver = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
            let r = interpret_scoped ~env ~sw child in
            Eio.Promise.resolve resolver r);
        Ok { promise; cancel = (fun () -> ()) }
    | S_await f -> Eio.Promise.await f.promise
    | S_interrupt f -> f.cancel (); Ok ()

  let run ~env eff = Eio.Switch.run @@ fun sw -> interpret ~env ~sw eff
end

(* === Auto-DI on collection combinators (inherited from F-A) === *)
let _check_par_unions_env () =
  let prog : (<db : <q : string -> int>; log : <i : string -> unit>; ..>,
              _, int * unit) Effect.t =
    Effect.par
      (Effect.sync (fun env -> env#db#q "a"))
      (Effect.sync (fun env -> env#log#i "b"))
  in
  prog

(* === Typed errors flow through await === *)
let _check_typed_error_through_await () =
  let open Effect in
  scoped {
    run = fun (type s) () : (s, _, [> `Db_err ], int) scoped_t ->
      let** (f : (s, [> `Db_err ], int) fiber) =
        fork (s_lift (fail `Db_err))
      in
      await f
  }
