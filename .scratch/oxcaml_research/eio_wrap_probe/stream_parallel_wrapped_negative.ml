open! Portable

module Stream_portable = struct
  type 'a t = { raw : 'a Eio.Stream.t }

  let create capacity =
    { raw = Eio.Stream.create capacity }

  let add t (item : 'a @ portable) =
    Eio.Stream.add t.raw item
end

let with_parallel f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> Parallel_scheduler.parallel scheduler ~f)

let bad () =
  Eio_main.run @@ fun _env ->
  let stream = Stream_portable.create 2 in
  with_parallel (fun parallel ->
    let #((), ()) =
      Parallel.fork_join2
        parallel
        (fun _ -> Stream_portable.add stream 1)
        (fun _ -> Stream_portable.add stream 2)
    in
    ())

let () = bad ()

