open! Portable

type env : immutable_data = { input : int }
type error = string Effet.Cause.Portable.t

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Pure : 'a -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, _) t
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
    | Catch (effect, h) -> (
        match run env effect with
        | Ok value -> Ok value
        | Error err -> run env (h err))
end

let program : (env, error, int) Effect.t =
  Effect.Catch
    ( Effect.Fail (Effet.Cause.Portable.Fail "typed"),
      function
      | Effet.Cause.Portable.Fail "typed" -> Effect.Pure 11
      | cause -> Effect.Fail cause )

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
                   ( Effect.Fail (Effet.Cause.Portable.Fail "typed"),
                     function
                     | Effet.Cause.Portable.Fail "typed" -> Effect.Pure 11
                     | cause -> Effect.Fail cause )))
            (fun _ ->
              Effect.run env
                (Effect.Catch
                   ( Effect.Fail (Effet.Cause.Portable.Fail "typed"),
                     function
                     | Effet.Cause.Portable.Fail "typed" -> Effect.Pure 11
                     | cause -> Effect.Fail cause )))
        in
        (left, right)))
  in
  match result with
  | Ok 11, Ok 11 -> Printf.printf "error=C cause_portable portable=true typed_channel=false\n%!"
  | _ -> failwith "Cause.Portable error did not roundtrip"
