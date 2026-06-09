open Eta_js
open Eta_js_test

let test_queue_rapid_ops () =
  let runtime = Runtime.create () in
  let q = Queue.unbounded () in
  let rec send_loop n acc =
    if n <= 0 then Effect.pure acc
    else
      Effect.bind
        (fun () -> send_loop (n - 1) (n :: acc))
        (Queue.send q n)
  in
  let rec recv_loop n acc =
    if n <= 0 then Effect.pure acc
    else
      Effect.bind
        (fun x -> recv_loop (n - 1) (x :: acc))
        (Queue.recv q)
  in
  Js.Promise.then_
    (fun _ ->
      Js.Promise.then_
        (fun exit ->
          (match exit with
          | Exit.Ok actual ->
              let expected = List.rev (List.init 100 (fun i -> i + 1)) in
              if actual = expected then ()
              else fail "queue_rapid" "recv mismatch" |> raise
          | _ -> fail "queue_rapid" "expected ok" |> raise);
          Js.Promise.resolve ())
        (Runtime.run_promise runtime (recv_loop 100 [])))
    (Runtime.run_promise runtime (send_loop 100 []))

let test_channel_ping_pong () =
  let runtime = Runtime.create () in
  let ch = Channel.create ~capacity:10 () in
  let count = 50 in
  let rec sender n =
    if n <= 0 then Effect.pure ()
    else
      Effect.bind
        (fun () -> sender (n - 1))
        (Channel.send ch n)
  in
  let rec receiver n acc =
    if n <= 0 then Effect.pure acc
    else
      Effect.bind
        (fun x -> receiver (n - 1) (x :: acc))
        (Channel.recv ch)
  in
  let p1 = Runtime.run_promise runtime (sender count) in
  let p2 = Runtime.run_promise runtime (receiver count []) in
  Js.Promise.then_
    (fun _ ->
      Js.Promise.then_
        (fun exit ->
          (match exit with
          | Exit.Ok actual ->
              let expected = List.rev (List.init count (fun i -> i + 1)) in
              if actual = expected then ()
              else fail "channel_ping_pong" "receive mismatch" |> raise
          | _ -> fail "channel_ping_pong" "expected ok" |> raise);
          Js.Promise.resolve ())
        p2)
    p1

let test_semaphore_contention () =
  let runtime = Runtime.create () in
  let sem = Semaphore.make ~permits:1 in
  let counter = Mutable_ref.make 0 in
  let worker () =
    Effect.bind
      (fun () ->
        Mutable_ref.set counter (Mutable_ref.get counter + 1);
        Semaphore.release sem 1;
        Effect.pure ())
      (Semaphore.acquire sem 1)
  in
  let rec spawn n =
    if n <= 0 then Effect.pure ()
    else
      Effect.bind
        (fun _ -> spawn (n - 1))
        (Effect.map (fun _ -> ()) (Effect.fork (worker ())))
  in
  Js.Promise.then_
    (fun _ ->
      let final = Mutable_ref.get counter in
      if final = 20 then ()
      else
        fail "semaphore_contention"
          ("expected counter 20, got " ^ string_of_int final)
        |> raise;
      Js.Promise.resolve ())
    (Runtime.run_promise runtime (spawn 20))

let test_deferred_racing () =
  let runtime = Runtime.create () in
  let d = Deferred.make_unsafe () in
  let p1 = Runtime.run_promise runtime (Deferred.succeed d 42) in
  let p2 = Runtime.run_promise runtime (Deferred.await d) in
  Js.Promise.then_
    (fun _ ->
      Js.Promise.then_
        (fun exit ->
          (match exit with
          | Exit.Ok actual ->
              if actual = 42 then ()
              else fail "deferred_racing" "await mismatch" |> raise
          | _ -> fail "deferred_racing" "expected ok" |> raise);
          Js.Promise.resolve ())
        p2)
    p1

let test_latch_countdown () =
  let runtime = Runtime.create () in
  let latch = Latch.make_unsafe () in
  let rec release_loop n =
    if n <= 0 then Effect.pure ()
    else Effect.bind (fun _ -> release_loop (n - 1)) (Latch.release latch)
  in
  let p1 = Runtime.run_promise runtime (release_loop 10) in
  let p2 = Runtime.run_promise runtime (Latch.await latch) in
  Js.Promise.then_
    (fun _ ->
      Js.Promise.then_
        (fun exit ->
          (match exit with
          | Exit.Ok () -> ()
          | _ -> fail "latch_countdown" "expected ok" |> raise);
          Js.Promise.resolve ())
        p2)
    p1

let tests =
  [
    ("queue_rapid_ops", test_queue_rapid_ops);
    ("channel_ping_pong", test_channel_ping_pong);
    ("semaphore_contention", test_semaphore_contention);
    ("deferred_racing", test_deferred_racing);
    ("latch_countdown", test_latch_countdown);
  ]
