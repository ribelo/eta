open Effet

module W = Wrappers

let run rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.asprintf "unexpected effect failure: %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
      |> failwith

let wrapper_queue_fixture rt =
  let q = W.Queue.create ~capacity:1 in
  let consumed = ref [] in
  let producer =
    Effect.concat
      [
        W.Queue.offer q 1;
        W.Queue.offer q 2;
        W.Queue.offer q 3;
        W.Queue.close q;
      ]
  in
  let rec consumer () =
    W.Queue.take q
    |> Effect.bind (fun value ->
           consumed := value :: !consumed;
           consumer ())
    |> Effect.catch (function
         | W.Queue.Closed -> Effect.pure ()
         | W.Queue.Failed _ -> Effect.pure ())
  in
  run rt (Effect.par producer (consumer ())) |> ignore;
  List.rev !consumed

let direct_queue_fixture () =
  let q = Eio.Stream.create 1 in
  let consumed = ref [] in
  Eio.Fiber.both
    (fun () ->
      Eio.Stream.add q (Some 1);
      Eio.Stream.add q (Some 2);
      Eio.Stream.add q (Some 3);
      Eio.Stream.add q None)
    (fun () ->
      let rec loop () =
        match Eio.Stream.take q with
        | Some value ->
            consumed := value :: !consumed;
            loop ()
        | None -> ()
      in
      loop ());
  List.rev !consumed

let wrapper_deferred_fixture rt =
  let config = W.Deferred.create () in
  let waiter =
    W.Deferred.await config |> Effect.map (fun value -> "loaded:" ^ value)
  in
  let program =
    Effect.par
      (Effect.all [ waiter; waiter; waiter ])
      (W.Deferred.succeed config "v1")
    |> Effect.map fst
  in
  run rt program

let direct_deferred_fixture () =
  let promise, resolver = Eio.Promise.create () in
  let results = Eio.Stream.create 3 in
  Eio.Fiber.both
    (fun () ->
      Eio.Fiber.both
        (fun () -> Eio.Stream.add results ("loaded:" ^ Eio.Promise.await promise))
        (fun () ->
          Eio.Fiber.both
            (fun () ->
              Eio.Stream.add results ("loaded:" ^ Eio.Promise.await promise))
            (fun () ->
              Eio.Stream.add results ("loaded:" ^ Eio.Promise.await promise))))
    (fun () -> Eio.Promise.resolve resolver "v1");
  [ Eio.Stream.take results; Eio.Stream.take results; Eio.Stream.take results ]
  |> List.sort String.compare

let wrapper_pubsub_fixture rt =
  let topic = W.Pubsub.create ~capacity:1 in
  let fast_ref = ref [] in
  let slow_ref = ref [] in
  let program =
    W.Pubsub.subscribe topic
    |> Effect.bind (fun fast ->
           W.Pubsub.subscribe topic
           |> Effect.bind (fun slow ->
                  let fast_consumer =
                    let rec loop remaining =
                      if remaining = 0 then Effect.pure ()
                      else
                        W.Pubsub.take fast
                        |> Effect.bind (fun value ->
                               fast_ref := value :: !fast_ref;
                               loop (remaining - 1))
                    in
                    loop 3
                  in
                  let publisher =
                    let yield = Effect.thunk "publisher.yield" Eio.Fiber.yield in
                    Effect.concat
                      [
                        W.Pubsub.publish topic 1 |> Effect.map ignore;
                        yield;
                        W.Pubsub.publish topic 2 |> Effect.map ignore;
                        yield;
                        W.Pubsub.publish topic 3 |> Effect.map ignore;
                        yield;
                        W.Pubsub.close topic;
                      ]
                  in
                  let slow_consumer =
                    W.Pubsub.take slow
                    |> Effect.bind (fun value ->
                           slow_ref := value :: !slow_ref;
                           Effect.pure ())
                  in
                  Effect.all [ fast_consumer; slow_consumer; publisher ]
                  |> Effect.map ignore))
  in
  run rt program;
  (List.rev !fast_ref, List.rev !slow_ref)

let direct_pubsub_fixture () =
  let fast = Eio.Stream.create 1 in
  let slow = Eio.Stream.create 1 in
  let publish value =
    if Eio.Stream.length fast < 1 then Eio.Stream.add fast (Some value);
    if Eio.Stream.length slow < 1 then Eio.Stream.add slow (Some value)
  in
  let fast_ref = ref [] in
  let slow_ref = ref [] in
  Eio.Fiber.both
    (fun () ->
      for i = 1 to 3 do
        publish i;
        Eio.Fiber.yield ()
      done;
      if Eio.Stream.length fast < 1 then Eio.Stream.add fast None;
      if Eio.Stream.length slow < 1 then Eio.Stream.add slow None)
    (fun () ->
      Eio.Fiber.both
        (fun () ->
          for _ = 1 to 3 do
            match Eio.Stream.take fast with
            | Some value -> fast_ref := value :: !fast_ref
            | None -> ()
          done)
        (fun () ->
          match Eio.Stream.take slow with
          | Some value -> slow_ref := value :: !slow_ref
          | None -> ()));
  (List.rev !fast_ref, List.rev !slow_ref)

let wrapper_latch_fixture rt =
  let latch = W.Latch.create 3 in
  let completed = ref false in
  let worker = W.Latch.count_down latch in
  let waiter = W.Latch.await latch |> Effect.map (fun () -> completed := true) in
  run rt (Effect.par waiter (Effect.all [ worker; worker; worker ])) |> ignore;
  !completed

let direct_latch_fixture () =
  let count = ref 3 in
  let mutex = Eio.Mutex.create () in
  let condition = Eio.Condition.create () in
  let count_down () =
    Eio.Mutex.use_rw ~protect:false mutex (fun () ->
        if !count > 0 then decr count;
        if !count = 0 then Eio.Condition.broadcast condition)
  in
  let completed = ref false in
  Eio.Fiber.both
    (fun () ->
      Eio.Mutex.use_ro mutex (fun () ->
          while !count > 0 do
            Eio.Condition.await condition mutex
          done);
      completed := true)
    (fun () -> List.iter (fun f -> f ()) [ count_down; count_down; count_down ]);
  !completed

let wrapper_tracing_fixture rt tracer =
  let q = W.Queue.create ~capacity:1 in
  let program =
    Effect.named "fixture.queue"
      (Effect.concat [ W.Queue.offer q 1; W.Queue.close q ])
  in
  run rt program;
  Effet.Tracer.dump tracer |> List.map (fun span -> span.Effet.Tracer.name)
