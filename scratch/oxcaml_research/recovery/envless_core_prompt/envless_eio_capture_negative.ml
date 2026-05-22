open! Portable

type error : immutable_data = Rejected of string

module Effect = struct
  type ('err : immutable_data, 'a : immutable_data) t =
    | Thunk : string * (unit -> 'a) @@ portable -> ('err, 'a) t

  let eval (Thunk (_, f)) = f ()
end

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let program : (error, int) Effect.t =
    Effect.Thunk ("bad-eio-capture", fun () -> int_of_float (Eio.Time.now clock))
  in
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         Parallel.fork_join2 parallel
           (fun _ -> Effect.eval program)
           (fun _ -> Effect.eval program))))
