open! Portable

class type clock = object
  method now_ms : int
end

type env = < clock : clock >
type error : immutable_data = { message : string }

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'err, 'a) t

  let run env (Thunk (_, f)) = f env
end

let clock : clock =
  object
    method now_ms = 42
  end

let env : env =
  object
    method clock = clock
  end

let program : (env, error, int) Effect.t =
  Effect.Thunk ("object-env", fun env -> env#clock#now_ms)

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         Parallel.fork_join2 parallel
           (fun _ -> Effect.run env program)
           (fun _ -> Effect.run env program))))

