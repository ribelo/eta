open! Portable

type clock : immutable_data = { now_ms : int }
type random : value mod portable contended = { seed : int Atomic.t }

type env : value mod portable contended = {
  clock : clock;
  random : random;
}

type error : immutable_data = {
  tag : string;
  message : string;
}

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, _) t
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'err, 'a) t
    | Bind :
        ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) @@ portable
        -> ('env, 'err, 'a) t
    | Map :
        ('env, 'err, 'b) t * ('b -> 'a) @@ portable -> ('env, 'err, 'a) t
    | Catch :
        ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t) @@ portable
        -> ('env, 'err2, 'a) t

  let rec run :
      type (env : value mod portable contended) (err : value mod portable)
           (a : value mod portable).
      env -> (env, err, a) t -> (a, err) result =
   fun env -> function
    | Pure value -> Ok value
    | Fail err -> Error err
    | Thunk (_, f) -> Ok (f env)
    | Bind (effect, k) -> (
        match run env effect with
        | Ok value -> run env (k value)
        | Error err -> Error err)
    | Map (effect, f) -> (
        match run env effect with
        | Ok value -> Ok (f value)
        | Error err -> Error err)
    | Catch (effect, h) -> (
        match run env effect with
        | Ok value -> Ok value
        | Error err -> run env (h err))
end

let next_seed seed = ((seed * 1_103_515_245) + 12_345) land 0x3fffffff

let program : (env, error, int) Effect.t =
  Effect.Bind
    ( Effect.Thunk
        ( "read-clock",
          fun env ->
            let seed = next_seed (Atomic.get env.random.seed) in
            Atomic.set env.random.seed seed;
            env.clock.now_ms + (seed land 7) ),
      fun n ->
        if n > 0 then Effect.Pure (n + 1)
        else Effect.Fail { tag = "bad_clock"; message = "clock must be positive" } )

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let env = { clock = { now_ms = 10 }; random = { seed = Atomic.make 17 } } in
  let left, right =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ ->
              Effect.run env
                (Effect.Bind
                   ( Effect.Thunk
                       ( "read-clock",
                         fun env ->
                           let seed = next_seed (Atomic.get env.random.seed) in
                           Atomic.set env.random.seed seed;
                           env.clock.now_ms + (seed land 7) ),
                     fun n ->
                       if n > 0 then Effect.Pure (n + 1)
                       else
                         Effect.Fail
                           {
                             tag = "bad_clock";
                             message = "clock must be positive";
                           } )))
            (fun _ ->
              Effect.run env
                (Effect.Bind
                   ( Effect.Thunk
                       ( "read-clock",
                         fun env ->
                           let seed = next_seed (Atomic.get env.random.seed) in
                           Atomic.set env.random.seed seed;
                           env.clock.now_ms + (seed land 7) ),
                     fun n ->
                       if n > 0 then Effect.Pure (n + 1)
                       else
                         Effect.Fail
                           {
                             tag = "bad_clock";
                             message = "clock must be positive";
                           } )))
        in
        (left, right)))
  in
  match (left, right) with
  | Ok a, Ok b ->
      if a <= 0 || b <= 0 then failwith "record env produced invalid result";
      Printf.printf "env=A closed_records portable=true result_sum=%d\n%!" (a + b)
  | Error _, _ | _, Error _ -> failwith "record env unexpectedly failed"
