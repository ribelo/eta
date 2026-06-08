open! Portable

type env : immutable_data = { input : int }
type error : immutable_data = [ `Rejected of string | `Timeout ]

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, _) t
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'err, 'a) t

  let run env = function
    | Pure value -> Ok value
    | Fail err -> Error err
    | Thunk (_, f) -> Ok (f env)
end

let program : (env, error, int) Effect.t =
  Effect.Thunk ("closed-polyvariant", fun env -> env.input + 1)

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let env = { input = 41 } in
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ -> Effect.run env program)
            (fun _ -> Effect.run env program)
        in
        (left, right)))
  in
  match result with
  | Ok 42, Ok 42 ->
      Printf.printf "error=A closed_polyvariant portable=true typed=true\n%!"
  | _ -> failwith "closed polyvariant did not roundtrip"

