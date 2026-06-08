open! Portable

type env : immutable_data = { input : int }

type timeout_error : immutable_data = { deadline_ms : int }
type rejected_error : immutable_data = { reason : string }

type error : immutable_data =
  | Timeout of timeout_error
  | Rejected of rejected_error

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, _) t
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'err, 'a) t
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
    | Catch (effect, h) -> (
        match run env effect with
        | Ok value -> Ok value
        | Error err -> run env (h err))
end

let program : (env, error, int) Effect.t =
  Effect.Catch
    ( Effect.Fail (Rejected { reason = "first" }),
      function
      | Rejected _ -> Effect.Pure 7
      | Timeout _ -> Effect.Fail (Rejected { reason = "unexpected timeout" }) )

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let env = { input = 0 } in
  let result =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ ->
              Effect.run env
                (Effect.Catch
                   ( Effect.Fail (Rejected { reason = "first" }),
                     function
                     | Rejected _ -> Effect.Pure 7
                     | Timeout _ ->
                         Effect.Fail
                           (Rejected { reason = "unexpected timeout" }) )))
            (fun _ ->
              Effect.run env
                (Effect.Catch
                   ( Effect.Fail (Rejected { reason = "first" }),
                     function
                     | Rejected _ -> Effect.Pure 7
                     | Timeout _ ->
                         Effect.Fail
                           (Rejected { reason = "unexpected timeout" }) )))
        in
        (left, right)))
  in
  match result with
  | Ok 7, Ok 7 -> Printf.printf "error=B closed_record_sum portable=true typed=true\n%!"
  | _ -> failwith "closed record errors did not roundtrip"
