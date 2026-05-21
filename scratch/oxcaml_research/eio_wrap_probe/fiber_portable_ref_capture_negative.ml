open! Portable

module Fiber_portable = struct
  let fork_join2 parallel (left : _ @ portable) (right : _ @ portable) =
    Parallel.fork_join2 parallel left right
end

let with_parallel f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> Parallel_scheduler.parallel scheduler ~f)

let bad () =
  let counter = ref 0 in
  with_parallel (fun parallel ->
    let #((), ()) =
      Fiber_portable.fork_join2
        parallel
        (fun _ -> incr counter)
        (fun _ -> incr counter)
    in
    ())

let () = bad ()

