(* F-A: Collection combinators only. No public Fiber.t.
   Surface: par, all, forEach_par. Failure mode: fail-fast,
   cancel siblings on first failure. *)

module Effect = struct
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Sync : ('env -> 'a) -> ('env, _, 'a) t
    | Bind : ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Par  : ('env, 'err, 'a) t * ('env, 'err, 'b) t
        -> ('env, 'err, 'a * 'b) t
    | All  : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
    | For_each_par :
        'x list * ('x -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a list) t

  let pure v = Pure v
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let fail e = Fail e
  let par a b = Par (a, b)
  let all xs = All xs
  let for_each_par xs f = For_each_par (xs, f)

  (* --- Eio-backed interpreter; minimal, fail-fast par/all. --- *)

  exception Failed of Obj.t

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
        run_n ~env [ Obj.magic a; Obj.magic b ] |> Result.map (function
          | [ x; y ] -> (Obj.obj x, Obj.obj y)
          | _ -> assert false)
    | All xs ->
        run_n ~env (List.map Obj.magic xs)
        |> Result.map (List.map Obj.obj)
    | For_each_par (xs, f) ->
        run_n ~env (List.map (fun x -> Obj.magic (f x)) xs)
        |> Result.map (List.map Obj.obj)

  and run_n : type env err. env:env ->
      (env, err, Obj.t) t list -> (Obj.t list, err) result =
   fun ~env children ->
    let n = List.length children in
    let results = Array.make n None in
    let first_err = ref None in
    let exception Stop in
    (try
      Eio.Switch.run @@ fun sw ->
      List.iteri
        (fun i child ->
          Eio.Fiber.fork ~sw (fun () ->
              match interpret ~env ~sw child with
              | Ok v -> results.(i) <- Some v
              | Error e ->
                  if !first_err = None then first_err := Some e;
                  Eio.Switch.fail sw Stop))
        children
    with Stop -> ());
    match !first_err with
    | Some e -> Error e
    | None ->
        Ok (Array.to_list results |> List.map (fun o -> Option.get o))

  let run ~env eff = Eio.Switch.run @@ fun sw -> interpret ~env ~sw eff
end

(* === Surface assertions === *)
module type FORK_API = sig
  val par : ('env, 'err, 'a) Effect.t -> ('env, 'err, 'b) Effect.t
    -> ('env, 'err, 'a * 'b) Effect.t
  val all : ('env, 'err, 'a) Effect.t list
    -> ('env, 'err, 'a list) Effect.t
  val for_each_par : 'x list -> ('x -> ('env, 'err, 'a) Effect.t)
    -> ('env, 'err, 'a list) Effect.t
end

module _ : FORK_API = Effect

(* === Auto-DI assertion: par/all keep the env-row dividend ===
   If you par two effects with different requirements, the result
   should union them automatically. *)

let check_par_unions_env =
  let need_db (s : <db : <q : string -> int>; ..>) =
    Effect.sync (fun _ -> s#db#q "x")
  in
  let need_log (s : <log : <i : string -> unit>; ..>) =
    Effect.sync (fun _ -> s#log#i "y")
  in
  fun () ->
    let _ = need_db and _ = need_log in
    (* Inferred type unions both rows. *)
    let prog : (<db : <q : string -> int>; log : <i : string -> unit>; ..>,
                _, int * unit) Effect.t =
      Effect.par
        (Effect.sync (fun env -> env#db#q "a"))
        (Effect.sync (fun env -> env#log#i "b"))
    in
    prog
