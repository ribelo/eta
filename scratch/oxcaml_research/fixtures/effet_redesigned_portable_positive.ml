(* Positive counterpart: an Effet-shaped GADT redesigned with a portable
   kind annotation. Same Pure/Thunk/Bind/Map shape as the shipped
   library, but domain-portable when its leaves are portable. *)

open! Portable

type ('env : value mod portable contended, 'err : immutable_data, 'a : immutable_data) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Fail : 'err -> ('env, 'err, _) t
  | Thunk :
      string * ('env -> 'a) @@ portable
      -> ('env, 'err, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ portable
      -> ('env, 'err, 'a) t
  | Map :
      ('env, 'err, 'b) t * ('b -> 'a) @@ portable
      -> ('env, 'err, 'a) t

let pure v = Pure v
let bind k e = Bind (e, k)
let map f e = Map (e, f)

let rec eval :
    type (env : value mod portable contended) (err : immutable_data) (a : immutable_data).
    env:env -> (env, err, a) t @ contended -> (a, err) result =
 fun ~env e ->
  match e with
  | Pure v -> Ok v
  | Fail err -> Error err
  | Thunk (_, f) -> Ok (f env)
  | Bind (inner, k) -> (
      match eval ~env inner with
      | Error err -> Error err
      | Ok v -> eval ~env (k v))
  | Map (inner, f) -> (
      match eval ~env inner with
      | Error err -> Error err
      | Ok v -> Ok (f v))

let () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      let program : (unit, string, int) t =
        bind
          (fun n -> pure (n * 2))
          (map (fun n -> n + 1) (pure 21))
      in
      let r =
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(a, b) =
              Parallel.fork_join2
                parallel
                (fun _ -> eval ~env:() program)
                (fun _ -> eval ~env:() program)
            in
            (a, b))
      in
      match r with
      | Ok 44, Ok 44 -> ()
      | _ -> failwith "redesigned portable Effect AST returned wrong value")
