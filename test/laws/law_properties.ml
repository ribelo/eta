(** Law observations are sealed to normalized [Exit.t] plus the ordered
    [Eta_test.Run.event] stream from fresh runs with the same explicit seed.
    Pending structured fibers are an additional cancellation side-condition.
    Generators are printable, shrinkable, and bounded: finite immutable effect
    blueprints (depth <= 3), total enumerated continuations, short finite
    interleavings/traces, valid schedule parameters, and a pending [never] only
    when a winner or failure owns its cancellation. Arbitrary [sync] bodies,
    external I/O, mutation shared between runs, and scheduler deadlines are not
    in the generated class. *)

module E = Eta.Effect
module Run = Eta_test.Run

let runtime_seed = 0xE22
let qcheck_seed = Random.State.make [| 0xE22; 0x5EA1 |]
let count = 50

type fn = Add of int | Log_add of int | Fail_even of int

type blueprint =
  | Pure of int
  | Fail of int
  | Log of int
  | Yield of int
  | Delay of int * int
  | Map of int * blueprint
  | Bind of fn * blueprint
  | Bind_error of fn * blueprint
  | Fold of int * int * blueprint
  | Finally of int * blueprint

let string_of_fn = function
  | Add n -> Printf.sprintf "add(%d)" n
  | Log_add n -> Printf.sprintf "log_add(%d)" n
  | Fail_even e -> Printf.sprintf "fail_even(%d)" e

let rec string_of_blueprint = function
  | Pure n -> Printf.sprintf "pure(%d)" n
  | Fail e -> Printf.sprintf "fail(%d)" e
  | Log n -> Printf.sprintf "log(%d)" n
  | Yield n -> Printf.sprintf "yield(%d)" n
  | Delay (ms, n) -> Printf.sprintf "delay(%d,%d)" ms n
  | Map (n, body) -> Printf.sprintf "map(%d,%s)" n (string_of_blueprint body)
  | Bind (fn, body) ->
      Printf.sprintf "bind(%s,%s)" (string_of_fn fn) (string_of_blueprint body)
  | Bind_error (fn, body) ->
      Printf.sprintf "bind_error(%s,%s)" (string_of_fn fn)
        (string_of_blueprint body)
  | Fold (ok, error, body) ->
      Printf.sprintf "fold(%d,%d,%s)" ok error (string_of_blueprint body)
  | Finally (tag, body) ->
      Printf.sprintf "finally(%d,%s)" tag (string_of_blueprint body)

let gen_int = QCheck.Gen.int_range (-20) 20
let gen_ms = QCheck.Gen.int_range 0 5

let gen_fn =
  let open QCheck.Gen in
  oneof_weighted
    [
      (3, map (fun n -> Add n) gen_int);
      (2, map (fun n -> Log_add n) gen_int);
      (2, map (fun n -> Fail_even n) gen_int);
    ]

let gen_leaf =
  let open QCheck.Gen in
  oneof_weighted
    [
      (3, map (fun n -> Pure n) gen_int);
      (2, map (fun n -> Fail n) gen_int);
      (2, map (fun n -> Log n) gen_int);
      (1, map (fun n -> Yield n) gen_int);
      (2, map2 (fun ms n -> Delay (ms, n)) gen_ms gen_int);
    ]

let rec gen_blueprint depth =
  let open QCheck.Gen in
  if depth = 0 then gen_leaf
  else
    let child = gen_blueprint (depth - 1) in
    oneof_weighted
      [
        (5, gen_leaf);
        (2, map2 (fun n body -> Map (n, body)) gen_int child);
        (2, map2 (fun fn body -> Bind (fn, body)) gen_fn child);
        (2, map2 (fun fn body -> Bind_error (fn, body)) gen_fn child);
        (1, map3 (fun a b body -> Fold (a, b, body)) gen_int gen_int child);
        (1, map2 (fun tag body -> Finally (tag, body)) gen_int child);
      ]

let shrink_fn = function
  | Add n -> QCheck.Iter.map (fun n -> Add n) (QCheck.Shrink.int n)
  | Log_add n ->
      QCheck.Iter.append (QCheck.Iter.return (Add n))
        (QCheck.Iter.map (fun n -> Log_add n) (QCheck.Shrink.int n))
  | Fail_even n ->
      QCheck.Iter.append (QCheck.Iter.return (Add n))
        (QCheck.Iter.map (fun n -> Fail_even n) (QCheck.Shrink.int n))

let rec shrink_blueprint blueprint =
  let open QCheck.Iter in
  match blueprint with
  | Pure n -> map (fun n -> Pure n) (QCheck.Shrink.int n)
  | Fail n -> map (fun n -> Fail n) (QCheck.Shrink.int n)
  | Log n ->
      append (return (Pure n)) (map (fun n -> Log n) (QCheck.Shrink.int n))
  | Yield n ->
      append (return (Pure n)) (map (fun n -> Yield n) (QCheck.Shrink.int n))
  | Delay (ms, n) ->
      append_l
        [
          return (Pure n);
          map (fun ms -> Delay (max 0 ms, n)) (QCheck.Shrink.int ms);
          map (fun n -> Delay (ms, n)) (QCheck.Shrink.int n);
        ]
  | Map (n, body) ->
      append_l
        [
          return body;
          map (fun n -> Map (n, body)) (QCheck.Shrink.int n);
          map (fun body -> Map (n, body)) (shrink_blueprint body);
        ]
  | Bind (fn, body) ->
      append_l
        [
          return body;
          map (fun fn -> Bind (fn, body)) (shrink_fn fn);
          map (fun body -> Bind (fn, body)) (shrink_blueprint body);
        ]
  | Bind_error (fn, body) ->
      append_l
        [
          return body;
          map (fun fn -> Bind_error (fn, body)) (shrink_fn fn);
          map (fun body -> Bind_error (fn, body)) (shrink_blueprint body);
        ]
  | Fold (ok, error, body) ->
      append_l
        [
          return body;
          map (fun ok -> Fold (ok, error, body)) (QCheck.Shrink.int ok);
          map (fun error -> Fold (ok, error, body)) (QCheck.Shrink.int error);
          map (fun body -> Fold (ok, error, body)) (shrink_blueprint body);
        ]
  | Finally (tag, body) ->
      append_l
        [
          return body;
          map (fun tag -> Finally (tag, body)) (QCheck.Shrink.int tag);
          map (fun body -> Finally (tag, body)) (shrink_blueprint body);
        ]

let blueprint =
  QCheck.make ~print:string_of_blueprint ~shrink:shrink_blueprint
    (gen_blueprint 3)

let fn = QCheck.make ~print:string_of_fn ~shrink:shrink_fn gen_fn
let bounded_int = QCheck.int_range (-20) 20
let positive = QCheck.int_range 1 8
let affine = QCheck.(pair (int_range (-3) 3) bounded_int)
let apply_affine (scale, offset) value = (scale * value) + offset

let apply_fn fn value =
  match fn with
  | Add n -> E.pure (value + n)
  | Log_add n ->
      E.bind
        (fun () -> E.pure (value + n))
        (E.log_info (Printf.sprintf "fn:%d:%d" n value))
  | Fail_even error -> if value mod 2 = 0 then E.fail error else E.pure value

let rec effect_of = function
  | Pure n -> E.pure n
  | Fail error -> E.fail error
  | Log n -> E.bind (fun () -> E.pure n) (E.log_info (Printf.sprintf "bp:%d" n))
  | Yield n -> E.bind (fun () -> E.pure n) E.yield
  | Delay (ms, n) -> E.delay (Eta.Duration.ms ms) (E.pure n)
  | Map (n, body) -> E.map (fun value -> value + n) (effect_of body)
  | Bind (fn, body) -> E.bind (apply_fn fn) (effect_of body)
  | Bind_error (fn, body) -> E.bind_error (apply_fn fn) (effect_of body)
  | Fold (ok, error, body) ->
      E.fold ~ok:(fun value -> value + ok) ~error:(fun value -> value + error)
        (effect_of body)
  | Finally (tag, body) ->
      E.finally (E.log_info (Printf.sprintf "cleanup:%d" tag)) (effect_of body)

let run program = Run.run ~seed:runtime_seed program

let sealed outcome =
  {
    outcome with
    Run.logs = [];
    spans = [];
    metrics = [];
    sleeps = [];
    pending_fibers = None;
  }

let equivalent ok error left right =
  let testable = Run.testable ok error in
  let left_sealed = sealed left and right_sealed = sealed right in
  if Alcotest.equal testable left_sealed right_sealed then true
  else
    let pp_int = Format.pp_print_int in
    QCheck.Test.fail_reportf "left:@.%a@.right:@.%a"
      (Run.pp pp_int pp_int) left (Run.pp pp_int pp_int) right

let no_pending outcome = outcome.Run.pending_fibers = Some []
let log_bodies outcome = List.map (fun record -> record.Eta.Logger.body) outcome.Run.logs
let count_log body outcome =
  List.fold_left
    (fun count record -> if record.Eta.Logger.body = body then count + 1 else count)
    0 outcome.Run.logs

let yields count body =
  E.bind (fun () -> body) (E.concat (List.init count (fun _ -> E.yield)))

type exit_kind = Success | Typed_failure | Defect | Cancellation

let all_exit_kinds = [ Success; Typed_failure; Defect; Cancellation ]

let direct_terminal = function
  | Success -> E.unit
  | Typed_failure -> E.fail 17
  | Defect -> E.die_message "generated defect"
  | Cancellation -> invalid_arg "cancellation requires a structured owner"

let exit_has_kind kind exit =
  match (kind, exit) with
  | Success, Eta.Exit.Ok () -> true
  | Typed_failure, Eta.Exit.Error (Eta.Cause.Fail 17) -> true
  | Defect, Eta.Exit.Error (Eta.Cause.Die { exn = Failure message; _ }) ->
      String.equal message "generated defect"
  | Cancellation, Eta.Exit.Error (Eta.Cause.Interrupt _) -> true
  | _ -> false

let lifecycle_root_has_kind kind exit =
  match kind with
  | Cancellation -> exit = Eta.Exit.Ok ()
  | Success | Typed_failure | Defect -> exit_has_kind kind exit

let lifecycle_program kind body =
  match kind with
  | Success | Typed_failure | Defect -> body (direct_terminal kind)
  | Cancellation ->
      E.race
        [
          body E.never;
          E.delay (Eta.Duration.ms 1) E.unit;
        ]

let property_map_identity =
  QCheck.Test.make ~name:"map identity" ~count blueprint (fun body ->
      let program = effect_of body in
      equivalent Alcotest.int Alcotest.int (run (E.map Fun.id program)) (run program))

let property_map_composition =
  QCheck.Test.make ~name:"map composition" ~count
    QCheck.(triple blueprint affine affine)
    (fun (body, f, g) ->
      let program = effect_of body in
      let left = E.map (apply_affine f) (E.map (apply_affine g) program) in
      let right = E.map (fun value -> apply_affine f (apply_affine g value)) program in
      equivalent Alcotest.int Alcotest.int (run left) (run right))

let property_bind_associativity =
  QCheck.Test.make ~name:"bind associativity" ~count QCheck.(triple blueprint fn fn)
    (fun (body, f, g) ->
      let program = effect_of body in
      let left = E.bind (apply_fn g) (E.bind (apply_fn f) program) in
      let right = E.bind (fun value -> E.bind (apply_fn g) (apply_fn f value)) program in
      equivalent Alcotest.int Alcotest.int (run left) (run right))

let property_bind_left_identity =
  QCheck.Test.make ~name:"pure/bind left identity" ~count QCheck.(pair bounded_int fn)
    (fun (value, f) ->
      equivalent Alcotest.int Alcotest.int
        (run (E.bind (apply_fn f) (E.pure value)))
        (run (apply_fn f value)))

let property_bind_right_identity =
  QCheck.Test.make ~name:"pure/bind right identity" ~count blueprint (fun body ->
      let program = effect_of body in
      equivalent Alcotest.int Alcotest.int (run (E.bind E.pure program)) (run program))

let property_bind_error_left_identity =
  QCheck.Test.make ~name:"bind_error left identity" ~count QCheck.(pair bounded_int fn)
    (fun (error, handler) ->
      equivalent Alcotest.int Alcotest.int
        (run (E.bind_error (apply_fn handler) (E.fail error)))
        (run (apply_fn handler error)))

let property_fold_coherence =
  QCheck.Test.make ~name:"fold coherence with map/bind_error" ~count
    QCheck.(triple blueprint bounded_int bounded_int)
    (fun (body, ok, error) ->
      let program = effect_of body in
      let left =
        E.fold ~ok:(fun value -> value + ok) ~error:(fun value -> value + error)
          program
      in
      let right =
        program |> E.map (fun value -> value + ok)
        |> E.bind_error (fun value -> E.pure (value + error))
      in
      equivalent Alcotest.int Alcotest.int (run left) (run right))

let property_par_pair_order =
  QCheck.Test.make ~name:"par pair input order" ~count
    QCheck.(quad bounded_int bounded_int positive positive)
    (fun (left, right, left_yields, right_yields) ->
      let outcome =
        run
          (E.par (yields left_yields (E.pure left))
             (yields right_yields (E.pure right)))
      in
      outcome.exit = Eta.Exit.Ok (left, right) && no_pending outcome)

let property_par_fail_fast =
  QCheck.Test.make
    ~name:"par fail-fast cancels pending sibling and waits for observable finalizer"
    ~count QCheck.(pair bounded_int positive)
    (fun (error, delay) ->
      let finalizer = Printf.sprintf "par-finalizer:%d" error in
      let sibling = E.finally (E.log_info finalizer) E.never in
      let failing = E.delay (Eta.Duration.ms delay) (E.fail error) in
      let outcome = run (E.discard (E.par sibling failing)) in
      outcome.exit = Eta.Exit.Error (Eta.Cause.Fail error)
      && count_log finalizer outcome = 1
      && no_pending outcome)

let interleaving = QCheck.(triple bounded_int positive (int_range 0 5))
let interleavings = QCheck.list_size (QCheck.Gen.int_range 0 8) interleaving

let property_map_par_order =
  QCheck.Test.make ~name:"map_par input order across interleavings" ~count
    interleavings (fun inputs ->
      let branch (value, yield_count, delay) =
        yields yield_count (E.delay (Eta.Duration.ms delay) (E.pure value))
      in
      let outcome = run (E.map_par ~max_concurrent:3 branch inputs) in
      outcome.exit = Eta.Exit.Ok (List.map (fun (value, _, _) -> value) inputs)
      && no_pending outcome)

let property_race_loser_cancellation =
  QCheck.Test.make ~name:"race pending-loser cancellation" ~count
    QCheck.(pair bounded_int positive)
    (fun (winner, delay) ->
      let finalizer = Printf.sprintf "race-finalizer:%d" winner in
      let loser = E.finally (E.log_info finalizer) E.never in
      let outcome = run (E.race [ loser; E.delay (Eta.Duration.ms delay) (E.pure winner) ]) in
      outcome.exit = Eta.Exit.Ok winner
      && count_log finalizer outcome = 1
      && no_pending outcome)

let property_finally_exactly_once =
  QCheck.Test.make
    ~name:"finally exactly once across success/typed-failure/defect/cancellation exit kinds"
    ~count bounded_int (fun tag ->
      let body_event = Printf.sprintf "finally-body:%d" tag in
      let finalizer = Printf.sprintf "finally:%d" tag in
      List.for_all
        (fun kind ->
          let body_exit_seen = ref false in
          let outcome =
            lifecycle_program kind (fun terminal ->
                let terminal =
                  E.on_exit
                    (fun exit ->
                      E.sync (fun () -> body_exit_seen := exit_has_kind kind exit))
                    terminal
                in
                E.finally (E.log_info finalizer)
                  (E.bind (fun () -> terminal) (E.log_info body_event)))
            |> run
          in
          !body_exit_seen
          && lifecycle_root_has_kind kind outcome.exit
          && log_bodies outcome = [ body_event; finalizer ]
          && count_log finalizer outcome = 1
          && no_pending outcome)
        all_exit_kinds)

let property_scope_lifo =
  QCheck.Test.make ~name:"scope reverse acquisition/release order" ~count
    QCheck.(list_size (Gen.int_range 1 6) bounded_int)
    (fun resources ->
      let acquire resource =
        E.acquire_release ~acquire:(E.pure resource)
          ~release:(fun resource -> E.log_info (Printf.sprintf "release:%d" resource))
      in
      let program =
        List.fold_right
          (fun resource rest -> E.bind (fun _ -> rest) (acquire resource))
          resources E.unit
        |> E.with_scope
      in
      let outcome = run program in
      outcome.exit = Eta.Exit.Ok ()
      && log_bodies outcome
         = List.rev_map (fun resource -> Printf.sprintf "release:%d" resource) resources
      && no_pending outcome)

let property_with_resource_all_exits =
  QCheck.Test.make
    ~name:"with_resource release across success/typed-failure/defect/cancellation exit kinds"
    ~count bounded_int (fun tag ->
      let body_event = Printf.sprintf "resource-body:%d" tag in
      let released = Printf.sprintf "resource-release:%d" tag in
      List.for_all
        (fun kind ->
          let body_exit_seen = ref false in
          let outcome =
            lifecycle_program kind (fun terminal ->
                let terminal =
                  E.on_exit
                    (fun exit ->
                      E.sync (fun () -> body_exit_seen := exit_has_kind kind exit))
                    terminal
                in
                E.with_resource ~acquire:(E.pure tag)
                  ~release:(fun _ -> E.log_info released)
                  (fun _ -> E.bind (fun () -> terminal) (E.log_info body_event)))
            |> run
          in
          !body_exit_seen
          && lifecycle_root_has_kind kind outcome.exit
          && log_bodies outcome = [ body_event; released ]
          && count_log released outcome = 1
          && no_pending outcome)
        all_exit_kinds)

let property_channel_close =
  QCheck.Test.make ~name:"Channel graceful close fence/drain/reason ordering" ~count
    QCheck.(pair bool (list_size (Gen.int_range 0 6) bounded_int))
    (fun (error_close, values) ->
      let channel = Eta.Channel.create ~capacity:(max 1 (List.length values)) () in
      let sends = List.map (Eta.Channel.send channel) values |> E.concat in
      let rec drain remaining acc =
        if remaining = 0 then E.pure (List.rev acc)
        else E.bind (fun value -> drain (remaining - 1) (value :: acc)) (Eta.Channel.recv channel)
      in
      let program =
        E.bind
          (fun () ->
            E.bind
              (fun () ->
                E.bind
                  (fun rejected ->
                    E.bind
                      (fun drained ->
                        E.bind
                          (fun after ->
                            E.map
                              (fun fenced -> (drained, after, fenced, rejected))
                              (Eta.Channel.try_send channel 999))
                          (Eta.Channel.try_recv channel))
                      (drain (List.length values) []))
                  (E.to_exit (Eta.Channel.send channel 998)))
              (E.sync (fun () ->
                   if error_close then (
                     Eta.Channel.close_with_error channel "first";
                     Eta.Channel.close channel)
                   else (
                     Eta.Channel.close channel;
                     Eta.Channel.close_with_error channel "second"))))
          sends
      in
      let outcome = run program in
      let expected =
        if error_close then
          Eta.Exit.Ok
            ( values,
              `Closed_with_error "first",
              `Closed_with_error "first",
              Eta.Exit.Error (Eta.Cause.Fail (`Closed_with_error "first")) )
        else
          Eta.Exit.Ok
            (values, `Closed, `Closed, Eta.Exit.Error (Eta.Cause.Fail `Closed))
      in
      let close channel =
        if error_close then (
          Eta.Channel.close_with_error channel "first";
          Eta.Channel.close channel)
        else (
          Eta.Channel.close channel;
          Eta.Channel.close_with_error channel "second")
      in
      let closed_cause =
        if error_close then Eta.Cause.Fail (`Closed_with_error "first")
        else Eta.Cause.Fail `Closed
      in
      let wake_receiver () =
        let channel = Eta.Channel.create ~capacity:1 () in
        let was_waiting = ref false in
        let receiver = E.map (fun _ -> ()) (Eta.Channel.recv channel) in
        let closer =
          yields 1
            (E.bind
               (fun () -> E.sync (fun () -> close channel))
               (E.sync (fun () ->
                    was_waiting :=
                      (Eta.Channel.stats channel).waiting_receivers = 1)))
        in
        let outcome = run (E.all_settled [ receiver; closer ]) in
        !was_waiting
        && outcome.exit = Eta.Exit.Ok [ Error closed_cause; Ok () ]
        && no_pending outcome
      in
      let wake_sender () =
        let channel = Eta.Channel.create ~capacity:1 () in
        let was_waiting = ref false in
        let closer =
          yields 1
            (E.bind
               (fun () -> E.sync (fun () -> close channel))
               (E.sync (fun () ->
                    was_waiting :=
                      (Eta.Channel.stats channel).waiting_senders = 1)))
        in
        let program =
          E.bind
            (fun () ->
              E.all_settled [ Eta.Channel.send channel 2; closer ])
            (Eta.Channel.send channel 1)
        in
        let outcome = run program in
        !was_waiting
        && outcome.exit = Eta.Exit.Ok [ Error closed_cause; Ok () ]
        && no_pending outcome
      in
      outcome.exit = expected
      && no_pending outcome
      && wake_receiver ()
      && wake_sender ())

let property_semaphore_cancellation =
  QCheck.Test.make
    ~name:"Semaphore waiting-cancellation safety/no permit consumption" ~count
    QCheck.(pair positive positive) (fun (capacity, delay) ->
      List.init capacity (fun index -> index + 1)
      |> List.for_all (fun requested ->
             let semaphore = Eta.Semaphore.make ~permits:capacity in
             let held = Eta.Semaphore.try_acquire semaphore capacity in
             let waiter =
               Eta.Semaphore.acquire semaphore requested
               |> E.map (fun () -> `Acquired)
               |> E.finally (E.log_info "semaphore-waiter-finalized")
             in
             let winner = E.delay (Eta.Duration.ms delay) (E.pure `Cancelled) in
             let outcome = run (E.race [ waiter; winner ]) in
             let safe =
               held && outcome.exit = Eta.Exit.Ok `Cancelled
               && Eta.Semaphore.waiting semaphore = 0
               && Eta.Semaphore.cancelled_waiters semaphore = 1
               && Eta.Semaphore.available semaphore = 0
               && count_log "semaphore-waiter-finalized" outcome = 1
               && no_pending outcome
             in
             Eta.Semaphore.release semaphore capacity;
             safe && Eta.Semaphore.available semaphore = capacity))

type close_reason = Clean | Error

let close_reason =
  QCheck.make ~print:(function Clean -> "clean" | Error -> "error")
    ~shrink:(function Error -> QCheck.Iter.return Clean | Clean -> QCheck.Iter.empty)
    QCheck.Gen.(oneof_list [ Clean; Error ])

let property_queue_close =
  QCheck.Test.make ~name:"Queue graceful close/error ordering" ~count
    QCheck.(pair close_reason (list_size (Gen.int_range 0 6) bounded_int))
    (fun (reason, values) ->
      let expected =
        match reason with
        | Clean ->
            Eta.Exit.Ok
              (values, `Closed, `Closed, Eta.Exit.Error (Eta.Cause.Fail `Closed))
        | Error ->
            Eta.Exit.Ok
              ( values,
                `Closed_with_error "first",
                `Closed_with_error "first",
                Eta.Exit.Error (Eta.Cause.Fail (`Closed_with_error "first")) )
      in
      let run_mode make_queue =
        let queue = make_queue () in
        let sends = List.map (Eta.Queue.send queue) values |> E.concat in
        let close () =
          match reason with
          | Clean ->
              Eta.Queue.close queue;
              Eta.Queue.close_with_error queue "second"
          | Error ->
              Eta.Queue.close_with_error queue "first";
              Eta.Queue.close queue
        in
        let rec drain remaining acc =
          if remaining = 0 then E.pure (List.rev acc)
          else
            E.bind (fun value -> drain (remaining - 1) (value :: acc))
              (Eta.Queue.take queue)
        in
        let program =
          E.bind
            (fun () ->
              E.bind
                (fun () ->
                  E.bind
                    (fun rejected ->
                      E.bind
                        (fun drained ->
                          E.bind
                            (fun after ->
                              E.map
                                (fun fenced -> (drained, after, fenced, rejected))
                                (Eta.Queue.try_offer queue 999))
                            (Eta.Queue.poll queue))
                        (drain (List.length values) []))
                    (E.to_exit (Eta.Queue.send queue 998)))
                (E.sync close))
            sends
        in
        let outcome = run program in
        outcome.exit = expected && no_pending outcome
      in
      let capacity = max 1 (List.length values) in
      List.for_all run_mode
        [
          Eta.Queue.unbounded;
          (fun () -> Eta.Queue.bounded ~capacity ());
          (fun () -> Eta.Queue.dropping ~capacity ());
          (fun () -> Eta.Queue.sliding ~capacity ());
        ])

let property_schedule_monotone =
  QCheck.Test.make
    ~name:"monotone delay sequences for valid exponential/fibonacci/linear schedules"
    ~count QCheck.(quad (int_range 0 2) (int_range 0 50) (int_range 0 10) positive)
    (fun (constructor, initial, step, length) ->
      let schedule =
        match constructor with
        | 0 ->
            Eta.Schedule.exponential ~factor:(1. +. (float_of_int step /. 4.))
              (Eta.Duration.ms initial)
        | 1 -> Eta.Schedule.fibonacci (Eta.Duration.ms initial)
        | _ ->
            Eta.Schedule.linear ~initial:(Eta.Duration.ms initial)
              ~step:(Eta.Duration.ms step)
      in
      let collect () =
        let rec loop driver remaining acc =
          if remaining = 0 then List.rev acc
          else
            match Eta.Schedule.next ~now_ms:0 ~input:() driver with
            | None -> List.rev acc
            | Some (metadata, next) ->
                loop next (remaining - 1) (Eta.Duration.to_ms metadata.delay :: acc)
        in
        loop (Eta.Schedule.start schedule) length []
      in
      let outcome = run (E.sync collect) in
      match outcome.exit with
      | Eta.Exit.Error _ -> false
      | Eta.Exit.Ok delays ->
          let rec monotone = function
            | [] | [ _ ] -> true
            | left :: (right :: _ as rest) -> left <= right && monotone rest
          in
          monotone delays && no_pending outcome)

let property_recurs_count =
  QCheck.Test.make ~name:"recurs n step count" ~count QCheck.(int_range 0 20)
    (fun recurrences ->
      let count_steps () =
        let rec loop driver count =
          match Eta.Schedule.next ~now_ms:0 ~input:() driver with
          | None -> count
          | Some (_, next) -> loop next (count + 1)
        in
        loop (Eta.Schedule.start (Eta.Schedule.recurs recurrences)) 0
      in
      let outcome = run (E.sync count_steps) in
      outcome.exit = Eta.Exit.Ok recurrences && no_pending outcome)

let fixed_clock now_ms : Eta.Capabilities.clock =
  object
    method now_ms () = now_ms
    method sleep _ = ()
  end

let probe name =
  E.bind
    (fun now ->
      E.bind
        (fun () -> E.map (fun () -> now) (E.named name E.unit))
        (E.log_info name))
    E.now_ms

let one_span = function [ span ] -> Some span | _ -> None

let property_override_restoration =
  QCheck.Test.make
    ~name:"dynamic override restoration across each exit kind" ~count
    QCheck.(pair (int_range 10 100) (int_range 100 1000))
    (fun (overridden_now, override_seed) ->
      let baseline = run (E.named "base-random-reference" E.unit) in
      let baseline_trace_id =
        Option.map (fun span -> span.Eta.Tracer.trace_id)
          (one_span baseline.spans)
      in
      let override_trace_id = ref None in
      List.for_all
        (fun kind ->
          let inside = Printf.sprintf "override-inside:%d" overridden_now in
          let after = "after-override" in
          let logger = Eta.Logger.in_memory () in
          let tracer = Eta.Tracer.in_memory () in
          let body_exit_seen = ref false in
          let body terminal =
            E.bind (fun _ -> terminal) (probe inside)
            |> E.on_exit (fun exit ->
                   E.sync (fun () -> body_exit_seen := exit_has_kind kind exit))
            |> E.finally
                 (if kind = Cancellation then E.log_info "override-cancel-finalizer"
                  else E.unit)
            |> E.with_clock (fixed_clock overridden_now)
            |> E.with_random (Eta.Capabilities.random_of_seed override_seed)
            |> E.with_logger (Eta.Logger.as_capability logger)
            |> E.with_tracer (Eta.Tracer.as_capability tracer)
          in
          let scoped =
            match kind with
            | Success | Typed_failure | Defect -> body (direct_terminal kind)
            | Cancellation ->
                E.timeout_as (Eta.Duration.ms 1) ~on_timeout:17 (body E.never)
          in
          let outcome =
            run
              (E.bind
                 (fun scoped_exit ->
                   E.bind
                     (fun now ->
                       E.bind
                         (fun () ->
                           E.map (fun () -> (scoped_exit, now))
                             (E.named after E.unit))
                         (E.log_info after))
                     E.now_ms)
                 (E.to_exit scoped))
          in
          let expected_scoped_exit = function
            | Cancellation, Eta.Exit.Error (Eta.Cause.Fail 17) -> true
            | (Success | Typed_failure | Defect as kind), exit ->
                exit_has_kind kind exit
            | _ -> false
          in
          let root_ok =
            match outcome.exit with
            | Eta.Exit.Ok (scoped_exit, after_now) ->
                expected_scoped_exit (kind, scoped_exit)
                && after_now <> overridden_now
            | Eta.Exit.Error _ -> false
          in
          let override_logs = Eta.Logger.dump logger in
          let expected_override_bodies =
            if kind = Cancellation then [ inside; "override-cancel-finalizer" ]
            else [ inside ]
          in
          let logger_ok =
            List.map (fun record -> record.Eta.Logger.body) override_logs
              = expected_override_bodies
            && List.for_all
                 (fun record -> record.Eta.Logger.ts_ms = overridden_now)
                 override_logs
            && (match outcome.logs with
               | [ record ] ->
                   record.Eta.Logger.body = after
                   && record.ts_ms <> overridden_now
               | _ -> false)
          in
          let tracer_ok =
            match (one_span (Eta.Tracer.dump tracer), one_span outcome.spans) with
            | Some inner_span, Some after_span ->
                let seeded =
                  match !override_trace_id with
                  | None ->
                      override_trace_id := Some inner_span.trace_id;
                      true
                  | Some expected -> expected = inner_span.trace_id
                in
                inner_span.name = inside
                && after_span.name = after
                && seeded
                && Some after_span.trace_id = baseline_trace_id
                && inner_span.trace_id <> after_span.trace_id
            | _ -> false
          in
          !body_exit_seen && root_ok && logger_ok && tracer_ok && no_pending outcome)
        all_exit_kinds)

let property_override_sibling_isolation =
  QCheck.Test.make ~name:"override sibling isolation under par" ~count
    QCheck.(triple (int_range 10 100) (int_range 100 1000) positive)
    (fun (overridden_now, override_seed, yield_count) ->
      let execute override_left =
        let override_name = if override_left then "override-left" else "override-right" in
        let base_name = if override_left then "base-right" else "base-left" in
        let logger = Eta.Logger.in_memory () in
        let tracer = Eta.Tracer.in_memory () in
        let overridden =
          yields yield_count (probe override_name)
          |> E.with_clock (fixed_clock overridden_now)
          |> E.with_random (Eta.Capabilities.random_of_seed override_seed)
          |> E.with_logger (Eta.Logger.as_capability logger)
          |> E.with_tracer (Eta.Tracer.as_capability tracer)
        in
        let base = yields yield_count (probe base_name) in
        let program = if override_left then E.par overridden base else E.par base overridden in
        let expected = if override_left then (overridden_now, 0) else (0, overridden_now) in
        let outcome = run program in
        match
          ( Eta.Logger.dump logger,
            outcome.logs,
            one_span (Eta.Tracer.dump tracer),
            one_span outcome.spans )
        with
        | [ override_log ], [ base_log ], Some override_span, Some base_span
          when outcome.exit = Eta.Exit.Ok expected
               && override_log.Eta.Logger.body = override_name
               && override_log.ts_ms = overridden_now
               && base_log.Eta.Logger.body = base_name
               && base_log.ts_ms = 0
               && override_span.name = override_name
               && base_span.name = base_name
               && override_span.trace_id <> base_span.trace_id
               && no_pending outcome ->
            Some (override_span.trace_id, base_span.trace_id)
        | _ -> None
      in
      match (execute true, execute false) with
      | Some (left_override, left_base), Some (right_override, right_base) ->
          left_override = right_override && left_base = right_base
      | _ -> false)

let property_log_pipeline =
  QCheck.Test.make ~name:"log pipeline order filter -> attrs -> transform -> sink" ~count
    QCheck.(pair bounded_int bounded_int)
    (fun (scope_value, call_value) ->
      let transform_calls = ref 0 in
      let attrs_seen = ref [] in
      let transform record =
        incr transform_calls;
        attrs_seen := record.Eta.Logger.attrs;
        E.Replace { record with body = "transformed" }
      in
      let program =
        E.bind
          (fun () -> E.log_error ~attrs:[ ("call", string_of_int call_value) ] "kept")
          (E.log_info "filtered")
        |> E.intercept_log transform
        |> E.annotate_logs [ ("scope", string_of_int scope_value) ]
        |> E.with_minimum_log_level Eta.Capabilities.Warn
      in
      let outcome = run program in
      let expected_attrs =
        [ ("scope", string_of_int scope_value); ("call", string_of_int call_value) ]
      in
      !transform_calls = 1
      && !attrs_seen = expected_attrs
      && (match outcome.logs with
         | [ record ] -> record.body = "transformed" && record.attrs = expected_attrs
         | _ -> false)
      && (match outcome.events with [ Run.Log _ ] -> true | _ -> false)
      && no_pending outcome)

let laws =
  [
    property_map_identity;
    property_map_composition;
    property_bind_associativity;
    property_bind_left_identity;
    property_bind_right_identity;
    property_bind_error_left_identity;
    property_fold_coherence;
    property_par_pair_order;
    property_par_fail_fast;
    property_map_par_order;
    property_race_loser_cancellation;
    property_finally_exactly_once;
    property_scope_lifo;
    property_with_resource_all_exits;
    property_channel_close;
    property_semaphore_cancellation;
    property_queue_close;
    property_schedule_monotone;
    property_recurs_count;
    property_override_restoration;
    property_override_sibling_isolation;
    property_log_pipeline;
  ]

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed laws
  in
  exit code
