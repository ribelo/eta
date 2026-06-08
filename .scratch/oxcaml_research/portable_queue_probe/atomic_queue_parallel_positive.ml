open! Portable

module Portable_queue = struct
  type ('a : immutable_data) t = { items : 'a list Atomic.t }

  let create () = { items = Atomic.make [] }

  let push t item =
    Atomic.update t.items ~pure_f:(fun items -> item :: items)

  let drain t =
    Atomic.exchange t.items []
end

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let push_range queue first last =
  for value = first to last do
    Portable_queue.push queue value
  done

let sum items = List.fold_left ( + ) 0 items

let () =
  let queue = Portable_queue.create () in
  with_scheduler (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #((), ()) =
        Parallel.fork_join2
          parallel
          (fun _ -> push_range queue 1 250)
          (fun _ -> push_range queue 251 500)
      in
      ()));
  let items = Portable_queue.drain queue in
  if List.length items <> 500
  then failwith "portable atomic queue lost items";
  if sum items <> 125250
  then failwith "portable atomic queue corrupted payloads"
