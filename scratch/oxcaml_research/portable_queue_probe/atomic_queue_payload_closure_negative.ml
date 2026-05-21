open! Portable

module Portable_queue = struct
  type ('a : immutable_data) t = { items : 'a list Atomic.t }

  let create () = { items = Atomic.make [] }

  let push t item =
    Atomic.update t.items ~pure_f:(fun items -> item :: items)
end

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  let queue = Portable_queue.create () in
  let counter = ref 0 in
  let payload () = !counter in
  with_scheduler (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #((), ()) =
        Parallel.fork_join2
          parallel
          (fun _ -> Portable_queue.push queue payload)
          (fun _ -> Portable_queue.push queue payload)
      in
      ()))
