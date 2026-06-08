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

let () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let result, resolve = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let value =
      with_parallel (fun parallel ->
        let #(left, right) =
          Fiber_portable.fork_join2 parallel (fun _ -> 20) (fun _ -> 22)
        in
        left + right)
    in
    Eio.Promise.resolve resolve value);
  match Eio.Promise.await result with
  | 42 -> ()
  | _ -> failwith "Parallel.fork_join did not compose inside Eio fiber"

