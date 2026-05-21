open! Portable

module Switch_local = struct
  type t = { raw : Eio.Switch.t }

  let run body =
    Eio.Switch.run (fun sw -> body { raw = sw })

  let fail t exn =
    Eio.Switch.fail t.raw exn
end

module Fiber_local = struct
  let fork (sw : Switch_local.t) body =
    Eio.Fiber.fork ~sw:sw.raw body
end

module Cancel_local = struct
  type t = Eio.Cancel.t

  let sub body =
    Eio.Cancel.sub (fun cancel -> body cancel)

  let cancel t exn =
    Eio.Cancel.cancel t exn

  let check t =
    Eio.Cancel.check t
end

module Stream_portable = struct
  type 'a t = { raw : 'a Eio.Stream.t }

  let create capacity =
    { raw = Eio.Stream.create capacity }

  let add t (item : 'a @ portable) =
    Eio.Stream.add t.raw item

  let take t =
    Eio.Stream.take t.raw
end

module Fiber_portable = struct
  let fork_join2 parallel (left : _ @ portable) (right : _ @ portable) =
    Parallel.fork_join2 parallel left right
end

let with_parallel f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> Parallel_scheduler.parallel scheduler ~f)

let main () =
  Eio_main.run @@ fun _env ->
  Switch_local.run @@ fun sw ->
  let stream = Stream_portable.create 2 in
  Stream_portable.add stream 40;
  let cancelled, cancelled_u = Eio.Promise.create () in
  Cancel_local.sub (fun cancel ->
    Fiber_local.fork sw (fun () ->
      try
        Eio.Fiber.yield ();
        Cancel_local.check cancel;
        Eio.Promise.resolve cancelled_u false
      with
      | Eio.Cancel.Cancelled _ -> Eio.Promise.resolve cancelled_u true);
    Cancel_local.cancel cancel Exit;
    Eio.Cancel.protect (fun () ->
      if not (Eio.Promise.await cancelled)
      then failwith "local cancellation wrapper did not cancel child fiber"));
  let parallel_sum =
    with_parallel (fun parallel ->
      let #(left, right) =
        Fiber_portable.fork_join2 parallel (fun _ -> 1) (fun _ -> 1)
      in
      left + right)
  in
  Stream_portable.add stream parallel_sum;
  match Stream_portable.take stream, Stream_portable.take stream with
  | 40, 2 -> ()
  | _ -> failwith "wrapped stream/fiber/parallel smoke returned wrong values"

let () = main ()
