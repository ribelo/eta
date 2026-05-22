open! Portable

type clock_tag
type random_tag

type clock_cap : immutable_data = { now_ms : int }
type random_cap : value mod portable contended = { seed : int Atomic.t }

type ('clock, 'random) env : value mod portable contended = {
  clock : clock_cap;
  random : random_cap;
}

type runtime_env = (clock_tag, random_tag) env
type error : immutable_data = { reason : string }

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, _) t
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'err, 'a) t
    | Map : ('env, 'err, 'b) t * ('b -> 'a) @@ portable -> ('env, 'err, 'a) t

  let rec run :
      type (env : value mod portable contended) (err : value mod portable)
           (a : value mod portable).
      env -> (env, err, a) t -> (a, err) result =
   fun env -> function
    | Pure value -> Ok value
    | Fail err -> Error err
    | Thunk (_, f) -> Ok (f env)
    | Map (effect, f) -> (
        match run env effect with
        | Ok value -> Ok (f value)
        | Error err -> Error err)
end

let program : (runtime_env, error, int) Effect.t =
  Effect.Map
    ( Effect.Thunk
        ( "phantom-env",
          fun env ->
            Atomic.incr env.random.seed;
            env.clock.now_ms + Atomic.get env.random.seed ),
      fun n -> n + 1 )

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let env = { clock = { now_ms = 20 }; random = { seed = Atomic.make 0 } } in
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ ->
              Effect.run env
                (Effect.Map
                   ( Effect.Thunk
                       ( "phantom-env",
                         fun env ->
                           Atomic.incr env.random.seed;
                           env.clock.now_ms + Atomic.get env.random.seed ),
                     fun n -> n + 1 )))
            (fun _ ->
              Effect.run env
                (Effect.Map
                   ( Effect.Thunk
                       ( "phantom-env",
                         fun env ->
                           Atomic.incr env.random.seed;
                           env.clock.now_ms + Atomic.get env.random.seed ),
                     fun n -> n + 1 )))
        in
        (left, right)))
  in
  match result with
  | Ok left, Ok right ->
      if left <= 20 || right <= 20 then failwith "phantom tuple env lost capability";
      Printf.printf "env=B phantom_tuple portable=true values=%d,%d\n%!" left right
  | _ -> failwith "phantom tuple env unexpectedly failed"
