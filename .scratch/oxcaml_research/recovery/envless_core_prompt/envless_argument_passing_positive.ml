open! Portable

type clock : immutable_data = { now_ms : int }
type random : value mod portable contended = { seed : int Atomic.t }
type error : immutable_data = Rejected of string

module Effect = struct
  type ('err : immutable_data, 'a : immutable_data) t =
    | Pure : 'a -> ('err, 'a) t
    | Fail : 'err -> ('err, _) t
    | Thunk : string * (unit -> 'a) @@ portable -> ('err, 'a) t
    | Bind :
        ('err, 'b) t * ('b -> ('err, 'a) t) @@ portable
        -> ('err, 'a) t
    | Map :
        ('err, 'b) t * ('b -> 'a) @@ portable
        -> ('err, 'a) t
    | Catch :
        ('err1, 'a) t * ('err1 -> ('err2, 'a) t) @@ portable
        -> ('err2, 'a) t

  let rec eval :
      type (err : immutable_data) (a : immutable_data).
      (err, a) t -> (a, err) result = function
    | Pure value -> Ok value
    | Fail err -> Error err
    | Thunk (_, f) -> Ok (f ())
    | Bind (effect, k) -> (
        match eval effect with
        | Ok value -> eval (k value)
        | Error err -> Error err)
    | Map (effect, f) -> (
        match eval effect with
        | Ok value -> Ok (f value)
        | Error err -> Error err)
    | Catch (effect, h) -> (
        match eval effect with
        | Ok value -> Ok value
        | Error err -> eval (h err))
end

let next_seed seed = ((seed * 1_103_515_245) + 12_345) land 0x3fffffff

let read_clock clock : (error, int) Effect.t =
  Effect.Thunk ("read-clock", fun () -> clock.now_ms)

let random_jitter random : (error, int) Effect.t =
  Effect.Thunk
    ( "random-jitter",
      fun () ->
        let seed = next_seed (Atomic.get random.seed) in
        Atomic.set random.seed seed;
        seed land 15 )

let program clock random : (error, int) Effect.t =
  Effect.Bind
    ( read_clock clock,
      fun now ->
        Effect.Map
          ( random_jitter random,
            fun jitter ->
              let result = now + jitter + 1 in
              if result <= 0 then 0 else result ) )

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let clock = { now_ms = 40 } in
  let random = { seed = Atomic.make 17 } in
  let left, right =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ -> Effect.eval (program clock random))
            (fun _ -> Effect.eval (program clock random))
        in
        (left, right)))
  in
  match (left, right) with
  | Ok a, Ok b ->
      if a <= 40 || b <= 40 then failwith "envless argument passing lost deps";
      Printf.printf
        "candidate=B envless ordinary_args=true portable=true effect_type_params=2 runtime_env=false result_sum=%d\n%!"
        (a + b)
  | Error _, _ | _, Error _ -> failwith "envless program unexpectedly failed"
