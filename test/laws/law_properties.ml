(** Law observations are sealed to normalized [Exit.t] plus the ordered
    [Eta_test.Run.event] stream from fresh runs with the same explicit seed.
    Pending structured fibers are an additional cancellation side-condition.
    Generators are printable, shrinkable, and bounded: finite immutable effect
    blueprints (depth <= 3; four base leaves and six recursive forms), total
    enumerated continuations, short finite interleavings/traces, valid schedule
    parameters, and a pending [never] only in separate lifecycle/concurrency
    matrices where a winner or failure owns its cancellation. The algebraic
    blueprint class has no defect or cancellation leaf. Arbitrary [sync] bodies,
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
  | Map of int * blueprint
  | Bind of fn * blueprint
  | Bind_error of fn * blueprint
  | Fold of int * int * blueprint
  | Finally of int * blueprint
  | Delay of int * blueprint

let string_of_fn = function
  | Add n -> Printf.sprintf "add(%d)" n
  | Log_add n -> Printf.sprintf "log_add(%d)" n
  | Fail_even e -> Printf.sprintf "fail_even(%d)" e

let rec string_of_blueprint = function
  | Pure n -> Printf.sprintf "pure(%d)" n
  | Fail e -> Printf.sprintf "fail(%d)" e
  | Log n -> Printf.sprintf "log(%d)" n
  | Yield n -> Printf.sprintf "yield(%d)" n
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
  | Delay (ms, body) ->
      Printf.sprintf "delay(%d,%s)" ms (string_of_blueprint body)

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
        (2, map2 (fun ms body -> Delay (ms, body)) gen_ms child);
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
  | Delay (ms, body) ->
      append_l
        [
          return body;
          map (fun ms -> Delay (max 0 ms, body)) (QCheck.Shrink.int ms);
          map (fun body -> Delay (ms, body)) (shrink_blueprint body);
        ]

let blueprint =
  QCheck.make ~print:string_of_blueprint ~shrink:shrink_blueprint
    (gen_blueprint 3)

let fn = QCheck.make ~print:string_of_fn ~shrink:shrink_fn gen_fn
let bounded_int = QCheck.int_range (-20) 20
let positive = QCheck.int_range 1 8
let negative = QCheck.int_neg

let nonpositive =
  QCheck.oneof_weighted ~print:string_of_int
    [ (1, QCheck.always ~print:string_of_int 0); (4, negative) ]

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
  | Map (n, body) -> E.map (fun value -> value + n) (effect_of body)
  | Bind (fn, body) -> E.bind (apply_fn fn) (effect_of body)
  | Bind_error (fn, body) -> E.bind_error (apply_fn fn) (effect_of body)
  | Fold (ok, error, body) ->
      E.fold ~ok:(fun value -> value + ok) ~error:(fun value -> value + error)
        (effect_of body)
  | Finally (tag, body) ->
      E.finally (E.log_info (Printf.sprintf "cleanup:%d" tag)) (effect_of body)
  | Delay (ms, body) -> E.delay (Eta.Duration.ms ms) (effect_of body)

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
  if not (left.Run.pending_fibers = Some [] && right.Run.pending_fibers = Some []) then
    QCheck.Test.fail_reportf
      "algebraic equivalence requires an exact empty pending-fiber census@.left:@.%a@.right:@.%a"
      (Run.pp Format.pp_print_int Format.pp_print_int) left
      (Run.pp Format.pp_print_int Format.pp_print_int) right
  else if Alcotest.equal testable left_sealed right_sealed then true
  else
    let pp_int = Format.pp_print_int in
    QCheck.Test.fail_reportf "left:@.%a@.right:@.%a"
      (Run.pp pp_int pp_int) left (Run.pp pp_int pp_int) right

let no_pending outcome = outcome.Run.pending_fibers = Some []
let raises_invalid_argument f =
  match f () with
  | exception Invalid_argument _ -> true
  | _ -> false

let log_bodies outcome = List.map (fun record -> record.Eta.Logger.body) outcome.Run.logs
let count_log body outcome =
  List.fold_left
    (fun count record -> if record.Eta.Logger.body = body then count + 1 else count)
    0 outcome.Run.logs

let yields count body =
  E.bind (fun () -> body) (E.concat (List.init count (fun _ -> E.yield)))

let complete_after ~delay ~event value =
  E.delay (Eta.Duration.ms delay)
    (E.bind (fun () -> E.pure value) (E.log_info event))

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

let effect_from_cause cause =
  E.Expert.make ~capabilities:[] (fun _ -> Eta.Exit.Error cause)

let property_bind_error_once_and_first_typed =
  QCheck.Test.make
    ~name:"bind_error handles exactly once with the first typed failure in cause order"
    ~count QCheck.(pair bounded_int bounded_int)
    (fun (first_error, recovered) ->
      let second_error = first_error + 1 in
      let typed_cause =
        Eta.Cause.concurrent
          [ Eta.Cause.Fail first_error; Eta.Cause.Fail second_error ]
      in
      let decisions = ref [] in
      let typed_outcome =
        run
          (E.bind_error
             (fun error ->
               E.bind
                 (fun () -> E.pure recovered)
                 (E.sync (fun () -> decisions := error :: !decisions)))
             (effect_from_cause typed_cause))
      in
      typed_outcome.exit = Eta.Exit.Ok recovered
      && !decisions = [ first_error ]
      && typed_outcome.events = []
      && no_pending typed_outcome)

let property_bind_error_uncatchable_boundary =
  QCheck.Test.make
    ~name:"bind_error never handles defect interruption or finalizer diagnostics"
    ~count QCheck.(pair bounded_int bounded_int)
    (fun (typed_error, recovered) ->
      let defect = Failure (Printf.sprintf "bind-error-defect:%d" recovered) in
      let defect_cause = Eta.Cause.die defect in
      let interrupt_cause = Eta.Cause.Interrupt None in
      let finalizer_cause =
        Eta.Cause.Finalizer
          (Eta.Cause.Finalizer.Fail
             (Printf.sprintf "bind-error-finalizer:%d" recovered))
      in
      let cases =
        [
          ( Eta.Cause.concurrent
              [ Eta.Cause.Fail typed_error; defect_cause ],
            defect_cause );
          ( Eta.Cause.concurrent
              [ Eta.Cause.Fail typed_error; interrupt_cause ],
            interrupt_cause );
          ( Eta.Cause.concurrent
              [ Eta.Cause.Fail typed_error; finalizer_cause ],
            finalizer_cause );
        ]
      in
      let handler_calls = ref 0 in
      let outcomes =
        List.map
          (fun (source, expected) ->
            let outcome =
              run
                (E.bind_error
                   (fun _ ->
                     E.bind
                       (fun () -> E.pure recovered)
                       (E.sync (fun () -> incr handler_calls)))
                   (effect_from_cause source))
            in
            (expected, outcome))
          cases
      in
      !handler_calls = 0
      && List.for_all
           (fun (expected, outcome) ->
             (match outcome.Run.exit with
             | Eta.Exit.Error actual ->
                 Eta.Cause.equal Int.equal expected actual
             | Eta.Exit.Ok _ -> false)
             && outcome.Run.events = []
             && no_pending outcome)
           outcomes)

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
  QCheck.Test.make
    ~name:"par preserves pair input order across both observable completion directions"
    ~count QCheck.(triple bounded_int bounded_int positive)
    (fun (left, right, base_delay) ->
      let execute left_first =
        let left_delay = base_delay + if left_first then 0 else 1 in
        let right_delay = base_delay + if left_first then 1 else 0 in
        let left_event = "par-complete:left" in
        let right_event = "par-complete:right" in
        let outcome =
          run
            (E.par
               (complete_after ~delay:left_delay ~event:left_event left)
               (complete_after ~delay:right_delay ~event:right_event right))
        in
        let expected_events =
          if left_first then [ left_event; right_event ]
          else [ right_event; left_event ]
        in
        outcome.exit = Eta.Exit.Ok (left, right)
        && log_bodies outcome = expected_events
        && no_pending outcome
      in
      execute true && execute false)

let property_par_fail_fast =
  QCheck.Test.make
    ~name:"par first observed failure cancels sibling tree and awaits cleanup"
    ~count QCheck.(pair bounded_int positive)
    (fun (first_error, first_delay) ->
      let first_delay = max 1 first_delay in
      let second_error = first_error + 1 in
      let pending_release = "par-release:pending" in
      let execute left_first =
        let left_delay = first_delay + if left_first then 0 else 1 in
        let right_delay = first_delay + if left_first then 1 else 0 in
        let left_event = Printf.sprintf "par-failure:left:%d" first_error in
        let right_event = Printf.sprintf "par-failure:right:%d" second_error in
        let left_release = "par-release:left-failure" in
        let right_release = "par-release:right-failure" in
        let fail_at delay event error release =
          E.finally (E.log_info release)
            (E.delay (Eta.Duration.ms delay)
               (E.bind (fun () -> E.fail error) (E.log_info event)))
        in
        let left = fail_at left_delay left_event first_error left_release in
        let right = fail_at right_delay right_event second_error right_release in
        let pending = E.finally (E.log_info pending_release) E.never in
        let outcome =
          run (E.discard (E.par left (E.par right pending)))
        in
        let winner_error, winner_event, loser_event =
          if left_first then (first_error, left_event, right_event)
          else (second_error, right_event, left_event)
        in
        let ok =
          (match outcome.exit with
          | Eta.Exit.Error cause -> Eta.Cause.failures cause = [ winner_error ]
          | Eta.Exit.Ok () -> false)
          && count_log winner_event outcome = 1
          && count_log loser_event outcome = 0
          && count_log left_release outcome = 1
          && count_log right_release outcome = 1
          && count_log pending_release outcome = 1
          && no_pending outcome
        in
        if ok then true
        else
          QCheck.Test.fail_reportf "left_first=%b logs=%s outcome:@.%a" left_first
            (String.concat "," (log_bodies outcome))
            (Run.pp (fun fmt () -> Format.pp_print_string fmt "()")
               Format.pp_print_int)
            outcome
      in
      execute true && execute false)

let property_map_par_order =
  QCheck.Test.make
    ~name:"map_par preserves input order across both observable completion directions"
    ~count
    QCheck.(pair (list_size (Gen.int_range 2 8) bounded_int) positive)
    (fun (values, base_delay) ->
      let indexed = List.mapi (fun index value -> (index, value)) values in
      let length = List.length values in
      let execute input_first =
        let branch (index, value) =
          let rank = if input_first then index else length - index - 1 in
          complete_after ~delay:(base_delay + rank)
            ~event:(Printf.sprintf "map-par-complete:%d" index)
            value
        in
        let outcome = run (E.map_par ~max_concurrent:length branch indexed) in
        let completion_indices =
          if input_first then List.init length Fun.id
          else List.init length (fun index -> length - index - 1)
        in
        outcome.exit = Eta.Exit.Ok values
        && log_bodies outcome
           = List.map
               (Printf.sprintf "map-par-complete:%d")
               completion_indices
        && no_pending outcome
      in
      execute true && execute false)

let property_map_par_fail_fast =
  QCheck.Test.make
    ~name:"map_par first failure cancels in-flight siblings and awaits scoped release"
    ~count QCheck.(pair bounded_int positive) (fun (error, delay) ->
      let delay = max 1 delay in
      let released index = Printf.sprintf "map-par-release:%d" index in
      let acquired = Array.make 2 false in
      let branch index =
        if index = 2 then E.delay (Eta.Duration.ms delay) (E.fail error)
        else
          E.bind
            (fun _ -> E.never)
            (E.acquire_release
               ~acquire:
                 (E.sync (fun () ->
                      acquired.(index) <- true;
                      index))
               ~release:(fun resource -> E.log_info (released resource)))
      in
      let outcome = run (E.discard (E.map_par ~max_concurrent:3 branch [ 0; 1; 2 ])) in
      let exit_ok =
        outcome.exit = Eta.Exit.Error (Eta.Cause.Fail error)
      in
      let ok =
        exit_ok
        && Array.to_list acquired = [ true; true ]
        && count_log (released 0) outcome = 1
        && count_log (released 1) outcome = 1
        && no_pending outcome
      in
      if ok then true
      else
        QCheck.Test.fail_reportf "acquired=%b,%b logs=%s outcome:@.%a"
          acquired.(0) acquired.(1)
          (String.concat "," (log_bodies outcome))
          (Run.pp (fun fmt () -> Format.pp_print_string fmt "()")
             Format.pp_print_int)
          outcome)

let property_map_par_max_concurrent =
  QCheck.Test.make
    ~name:"map_par never exceeds max_concurrent and reaches the bound when inputs suffice"
    ~count
    QCheck.(pair (list_size (Gen.int_range 1 12) bounded_int) (int_range 1 8))
    (fun (values, requested_bound) ->
      let in_flight = ref 0 in
      let maximum = ref 0 in
      let branch value =
        let enter =
          E.sync (fun () ->
              incr in_flight;
              maximum := max !maximum !in_flight)
        in
        let leave = E.sync (fun () -> decr in_flight) in
        E.bind
          (fun () -> E.finally leave (E.delay (Eta.Duration.ms 1) (E.pure value)))
          enter
      in
      let outcome = run (E.map_par ~max_concurrent:requested_bound branch values) in
      let effective_bound = min requested_bound (List.length values) in
      outcome.exit = Eta.Exit.Ok values
      && !maximum = effective_bound
      && !in_flight = 0
      && List.length outcome.sleeps = List.length values
      && List.for_all
           (fun duration -> Eta.Duration.to_ms duration = 1)
           outcome.sleeps
      && no_pending outcome)

let concurrent_values =
  QCheck.(pair (list_size (Gen.int_range 2 8) bounded_int) positive)

let property_all_input_order =
  QCheck.Test.make
    ~name:"all collects results in input order after reverse observable completion"
    ~count concurrent_values (fun (values, base_delay) ->
      let length = List.length values in
      let children =
        List.mapi
          (fun index value ->
            complete_after ~delay:(base_delay + length - index - 1)
              ~event:(Printf.sprintf "all-complete:%d" index)
              value)
          values
      in
      let outcome = run (E.all children) in
      outcome.exit = Eta.Exit.Ok values
      && log_bodies outcome
         = List.init length (fun index ->
               Printf.sprintf "all-complete:%d" (length - index - 1))
      && no_pending outcome)

let property_all_fail_fast =
  QCheck.Test.make
    ~name:"all first observed failure cancels siblings and awaits their finalizers"
    ~count QCheck.(pair bounded_int positive) (fun (first_error, first_delay) ->
      let first_delay = max 1 first_delay in
      let later_error = first_error + 1 in
      let first_event = Printf.sprintf "all-failure:first:%d" first_error in
      let later_event = Printf.sprintf "all-failure:later:%d" later_error in
      let later_release = "all-release:later-failure" in
      let pending_release = "all-release:pending" in
      let fail_at delay event error =
        E.delay (Eta.Duration.ms delay)
          (E.bind (fun () -> E.fail error) (E.log_info event))
      in
      let first = fail_at first_delay first_event first_error in
      let later =
        E.finally (E.log_info later_release)
          (fail_at (first_delay + 1) later_event later_error)
      in
      let pending = E.finally (E.log_info pending_release) E.never in
      let outcome = run (E.discard (E.all [ first; later; pending ])) in
      outcome.exit = Eta.Exit.Error (Eta.Cause.Fail first_error)
      && count_log first_event outcome = 1
      && count_log later_event outcome = 0
      && count_log later_release outcome = 1
      && count_log pending_release outcome = 1
      && outcome.sleeps
         = [ Eta.Duration.ms first_delay; Eta.Duration.ms (first_delay + 1) ]
      && no_pending outcome)

let defect_message expected = function
  | Eta.Cause.Die
      {
        exn = Failure actual;
        backtrace = None;
        span_name = None;
        annotations = [];
      } ->
      String.equal expected actual
  | _ -> false

let property_all_settled_input_order_and_capture =
  QCheck.Test.make
    ~name:"all_settled captures every child cause and preserves input order"
    ~count QCheck.(triple bounded_int bounded_int positive)
    (fun (value, error, base_delay) ->
      let defect = Printf.sprintf "all-settled-defect:%d" value in
      let children =
        [
          complete_after ~delay:(base_delay + 2)
            ~event:"all-settled-complete:success" value;
          E.delay (Eta.Duration.ms base_delay) (E.fail error);
          E.delay (Eta.Duration.ms (base_delay + 1)) (E.die_message defect);
        ]
      in
      let outcome = run (E.all_settled children) in
      match outcome.exit with
      | Eta.Exit.Ok [ Ok actual; Error (Eta.Cause.Fail actual_error); Error cause ] ->
          actual = value && actual_error = error && defect_message defect cause
          && log_bodies outcome = [ "all-settled-complete:success" ]
          && no_pending outcome
      | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false)

let property_race_first_value =
  QCheck.Test.make
    ~name:"race returns the actual first distinctly tagged finite producer"
    ~count QCheck.(triple bounded_int bounded_int positive)
    (fun (left_value, right_value, first_delay) ->
      let execute left_first =
        let left_delay = first_delay + if left_first then 0 else 1 in
        let right_delay = first_delay + if left_first then 1 else 0 in
        let left_event = "race-complete:left" in
        let right_event = "race-complete:right" in
        let left =
          complete_after ~delay:left_delay ~event:left_event (`Left left_value)
        in
        let right =
          complete_after ~delay:right_delay ~event:right_event (`Right right_value)
        in
        let outcome = run (E.race [ left; right ]) in
        let expected_exit, expected_event =
          if left_first then (Eta.Exit.Ok (`Left left_value), left_event)
          else (Eta.Exit.Ok (`Right right_value), right_event)
        in
        outcome.exit = expected_exit
        && log_bodies outcome = [ expected_event ]
        && no_pending outcome
      in
      execute true && execute false)

let property_race_loser_cancellation =
  QCheck.Test.make
    ~name:"race loser cancellation releases an actually held scoped resource"
    ~count
    QCheck.(pair bounded_int positive)
    (fun (winner, delay) ->
      let release_event = Printf.sprintf "race-resource-release:%d" winner in
      let acquired = ref false in
      let released = ref false in
      let loser =
        E.with_scope
          (E.bind
             (fun _ -> E.never)
             (E.acquire_release
                ~acquire:
                  (E.sync (fun () ->
                       acquired := true;
                       winner))
                ~release:(fun _ ->
                  E.bind
                    (fun () -> E.log_info release_event)
                    (E.sync (fun () -> released := true)))))
      in
      let outcome = run (E.race [ loser; E.delay (Eta.Duration.ms delay) (E.pure winner) ]) in
      outcome.exit = Eta.Exit.Ok winner
      && !acquired
      && !released
      && log_bodies outcome = [ release_event ]
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

let property_finally_cleanup_failure_after_success =
  QCheck.Test.make
    ~name:"finally cleanup failure after success is a finalizer cause" ~count
    QCheck.(pair bounded_int bounded_int)
    (fun (value, cleanup_error) ->
      let outcome =
        E.finally (E.fail cleanup_error) (E.pure value)
        |> E.with_error_pp Format.pp_print_int |> run
      in
      outcome.exit
      = Eta.Exit.Error
          (Eta.Cause.Finalizer
             (Eta.Cause.Finalizer.Fail (string_of_int cleanup_error)))
      && no_pending outcome)

let property_finally_cleanup_failure_suppressed =
  QCheck.Test.make
    ~name:"finally cleanup failure is suppressed under a primary failure" ~count
    QCheck.(pair bounded_int bounded_int)
    (fun (primary_error, cleanup_error) ->
      let outcome =
        E.finally (E.fail cleanup_error) (E.fail primary_error)
        |> E.with_error_pp Format.pp_print_int |> run
      in
      outcome.exit
      = Eta.Exit.Error
          (Eta.Cause.Suppressed
             {
               primary = Eta.Cause.Fail primary_error;
               finalizer =
                 Eta.Cause.Finalizer.Fail (string_of_int cleanup_error);
             })
      && no_pending outcome)

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

let property_nested_scope_release_boundary =
  QCheck.Test.make
    ~name:"nested with_scope releases inner resources before outer continuation and finalizer"
    ~count QCheck.(pair bounded_int bounded_int)
    (fun (outer_tag, inner_tag) ->
      let inner_body = Printf.sprintf "nested-scope:inner-body:%d" inner_tag in
      let inner_release = Printf.sprintf "nested-scope:inner-release:%d" inner_tag in
      let outer_continuation =
        Printf.sprintf "nested-scope:outer-continuation:%d" outer_tag
      in
      let outer_release = Printf.sprintf "nested-scope:outer-release:%d" outer_tag in
      let inner =
        E.with_scope
          (E.bind
             (fun _ -> E.log_info inner_body)
             (E.acquire_release ~acquire:(E.pure inner_tag)
                ~release:(fun _ -> E.log_info inner_release)))
      in
      let program =
        E.with_scope
          (E.bind
             (fun _ ->
               E.bind (fun () -> E.log_info outer_continuation) inner)
             (E.acquire_release ~acquire:(E.pure outer_tag)
                ~release:(fun _ -> E.log_info outer_release)))
      in
      let outcome = run program in
      outcome.exit = Eta.Exit.Ok ()
      && log_bodies outcome
         = [ inner_body; inner_release; outer_continuation; outer_release ]
      && no_pending outcome)

let property_with_scope_release_all_exits =
  QCheck.Test.make
    ~name:"with_scope releases registered resources on success typed failure defect and cancellation"
    ~count bounded_int (fun tag ->
      let released = Printf.sprintf "scope-release:%d" tag in
      List.for_all
        (fun kind ->
          let outcome =
            lifecycle_program kind (fun terminal ->
                E.with_scope
                  (E.bind
                     (fun _ -> terminal)
                     (E.acquire_release ~acquire:(E.pure tag)
                        ~release:(fun _ -> E.log_info released))))
            |> run
          in
          lifecycle_root_has_kind kind outcome.exit
          && log_bodies outcome = [ released ]
          && no_pending outcome)
        all_exit_kinds)

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

let property_with_resource_release_failure_after_success =
  QCheck.Test.make
    ~name:"with_resource release failure after body success becomes Cause.Finalizer"
    ~count QCheck.(triple bounded_int bounded_int bounded_int)
    (fun (resource, body_value, release_error) ->
      let released_resource = ref None in
      let release actual =
        E.bind
          (fun () -> E.fail release_error)
          (E.sync (fun () -> released_resource := Some actual))
      in
      let outcome =
        E.with_resource ~acquire:(E.pure resource) ~release (fun actual ->
            E.pure (body_value + (actual - resource)))
        |> E.with_error_pp Format.pp_print_int |> run
      in
      outcome.exit
      = Eta.Exit.Error
          (Eta.Cause.Finalizer
             (Eta.Cause.Finalizer.Fail (string_of_int release_error)))
      && !released_resource = Some resource
      && outcome.events = []
      && no_pending outcome)

let property_acquire_use_release_failure_suppressed =
  QCheck.Test.make
    ~name:"acquire_use_release release failure is suppressed under body failure"
    ~count QCheck.(triple bounded_int bounded_int bounded_int)
    (fun (resource, primary_error, release_error) ->
      let released_resource = ref None in
      let release actual =
        E.bind
          (fun () -> E.fail release_error)
          (E.sync (fun () -> released_resource := Some actual))
      in
      let outcome =
        E.acquire_use_release ~acquire:(E.pure resource) ~release (fun actual ->
            if actual = resource then E.fail primary_error
            else E.fail (primary_error + 1))
        |> E.with_error_pp Format.pp_print_int |> run
      in
      outcome.exit
      = Eta.Exit.Error
          (Eta.Cause.Suppressed
             {
               primary = Eta.Cause.Fail primary_error;
               finalizer =
                 Eta.Cause.Finalizer.Fail (string_of_int release_error);
             })
      && !released_resource = Some resource
      && outcome.events = []
      && no_pending outcome)

let property_channel_blocked_sender_fifo =
  QCheck.Test.make
    ~name:"Channel admits active blocked senders FIFO as capacity opens" ~count
    QCheck.(pair bounded_int (list_size (Gen.int_range 1 6) bounded_int))
    (fun (initial, blocked_values) ->
      let channel = Eta.Channel.create ~capacity:1 () in
      let waiting_seen = ref false in
      let rec recv_all remaining acc =
        if remaining = 0 then E.pure (List.rev acc)
        else
          E.bind
            (fun value -> recv_all (remaining - 1) (value :: acc))
            (Eta.Channel.recv channel)
      in
      let senders = List.map (Eta.Channel.send channel) blocked_values in
      let receiver =
        yields 1
          (E.bind
             (fun () -> recv_all (List.length blocked_values + 1) [])
             (E.sync (fun () ->
                  waiting_seen :=
                    (Eta.Channel.stats channel).waiting_senders
                    = List.length blocked_values)))
      in
      let program =
        E.bind
          (fun () ->
            E.map (fun (_, received) -> received) (E.par (E.all senders) receiver))
          (Eta.Channel.send channel initial)
      in
      let outcome = run program in
      !waiting_seen
      && outcome.exit = Eta.Exit.Ok (initial :: blocked_values)
      && no_pending outcome)

let property_channel_capacity_validation =
  QCheck.Test.make
    ~name:"Channel create rejects every generated nonpositive capacity and accepts positive capacity"
    ~count QCheck.(pair nonpositive positive)
    (fun (invalid_capacity, valid_capacity) ->
      let rejected =
        raises_invalid_argument (fun () ->
            Eta.Channel.create ~capacity:invalid_capacity ())
      in
      let channel = Eta.Channel.create ~capacity:valid_capacity () in
      let outcome = run (Eta.Channel.try_recv channel) in
      rejected && outcome.exit = Eta.Exit.Ok `Empty && no_pending outcome)

let property_channel_blocking_boundaries =
  QCheck.Test.make
    ~name:"Channel send waits while full and recv waits while empty until the opposite operation commits"
    ~count QCheck.(pair positive bounded_int)
    (fun (capacity, value) ->
      let full_channel = Eta.Channel.create ~capacity () in
      let sender_waiting = ref false in
      let fill =
        List.init capacity (fun index -> Eta.Channel.send full_channel index)
        |> E.concat
      in
      let blocked_sender = Eta.Channel.send full_channel value in
      let make_space =
        yields 1
          (E.bind
             (fun () -> E.discard (Eta.Channel.recv full_channel))
             (E.sync (fun () ->
                  sender_waiting :=
                    (Eta.Channel.stats full_channel).waiting_senders = 1)))
      in
      let full_outcome =
        run (E.bind (fun () -> E.par blocked_sender make_space) fill)
      in
      let empty_channel = Eta.Channel.create ~capacity () in
      let receiver_waiting = ref false in
      let blocked_receiver = Eta.Channel.recv empty_channel in
      let provide_value =
        yields 1
          (E.bind
             (fun () -> Eta.Channel.send empty_channel value)
             (E.sync (fun () ->
                  receiver_waiting :=
                    (Eta.Channel.stats empty_channel).waiting_receivers = 1)))
      in
      let empty_outcome = run (E.par blocked_receiver provide_value) in
      !sender_waiting
      && full_outcome.exit = Eta.Exit.Ok ((), ())
      && (Eta.Channel.stats full_channel).depth = capacity
      && no_pending full_outcome
      && !receiver_waiting
      && empty_outcome.exit = Eta.Exit.Ok (value, ())
      && (Eta.Channel.stats empty_channel).depth = 0
      && no_pending empty_outcome)

let property_channel_blocked_sender_cancellation =
  QCheck.Test.make
    ~name:"Channel blocked-sender cancellation removes waiter increments counter and consumes no value"
    ~count QCheck.(triple bounded_int bounded_int positive)
    (fun (initial, cancelled_value, delay) ->
      let channel = Eta.Channel.create ~capacity:1 () in
      let cancelled_send =
        Eta.Channel.send channel cancelled_value |> E.map (fun () -> `Sent)
      in
      let cancel = E.delay (Eta.Duration.ms delay) (E.pure `Cancelled) in
      let program =
        E.bind
          (fun () ->
            E.bind
              (fun winner ->
                E.bind
                  (fun stats ->
                    E.bind
                      (fun received ->
                        E.map
                          (fun after -> (winner, stats, received, after))
                          (Eta.Channel.try_recv channel))
                      (Eta.Channel.recv channel))
                  (E.sync (fun () -> Eta.Channel.stats channel)))
              (E.race [ cancelled_send; cancel ]))
          (Eta.Channel.send channel initial)
      in
      let outcome = run program in
      match outcome.exit with
      | Eta.Exit.Ok (`Cancelled, stats, received, `Empty) ->
          stats.Eta.Channel.waiting_senders = 0
          && stats.cancelled_senders = 1
          && stats.depth = 1
          && stats.sent = 1
          && received = initial
          && no_pending outcome
      | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false)

let property_channel_try_boundaries =
  QCheck.Test.make
    ~name:"Channel try_send and try_recv return exact no-wait empty full item and close boundaries"
    ~count QCheck.(pair bool bounded_int)
    (fun (error_close, value) ->
      let capacity_validation =
        raises_invalid_argument (fun () -> Eta.Channel.create ~capacity:0 ())
        && raises_invalid_argument (fun () ->
               Eta.Channel.create ~capacity:(-1) ())
      in
      let channel = Eta.Channel.create ~capacity:1 () in
      let close () =
        if error_close then Eta.Channel.close_with_error channel "channel-error"
        else Eta.Channel.close channel
      in
      let program =
        E.bind
          (fun initially_empty ->
            E.bind
              (fun sent ->
                E.bind
                  (fun full ->
                    E.bind
                      (fun item ->
                        E.bind
                          (fun empty_again ->
                            E.bind
                              (fun () ->
                                E.bind
                                  (fun closed_send ->
                                    E.map
                                      (fun closed_recv ->
                                        ( initially_empty,
                                          sent,
                                          full,
                                          item,
                                          empty_again,
                                          closed_send,
                                          closed_recv ))
                                      (Eta.Channel.try_recv channel))
                                  (Eta.Channel.try_send channel (value + 2)))
                              (E.sync close))
                          (Eta.Channel.try_recv channel))
                      (Eta.Channel.try_recv channel))
                  (Eta.Channel.try_send channel (value + 1)))
              (Eta.Channel.try_send channel value))
          (Eta.Channel.try_recv channel)
      in
      let close_result =
        if error_close then `Closed_with_error "channel-error" else `Closed
      in
      let outcome = run program in
      capacity_validation
      && outcome.exit
      = Eta.Exit.Ok
          (`Empty, `Sent, `Full, `Item value, `Empty, close_result, close_result)
      && no_pending outcome)

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

let property_channel_close_effect_wrappers =
  QCheck.Test.make
    ~name:"Channel close effect wrappers have the same fence drain and reason as direct close"
    ~count QCheck.(pair bool (list_size (Gen.int_range 0 6) bounded_int))
    (fun (error_close, values) ->
      let execute effectful =
        let channel =
          Eta.Channel.create ~capacity:(max 1 (List.length values)) ()
        in
        let close =
          match (error_close, effectful) with
          | false, false -> E.sync (fun () -> Eta.Channel.close channel)
          | false, true -> Eta.Channel.close_effect channel
          | true, false ->
              E.sync (fun () ->
                  Eta.Channel.close_with_error channel "channel-error")
          | true, true ->
              Eta.Channel.close_with_error_effect channel "channel-error"
        in
        let rec drain remaining acc =
          if remaining = 0 then E.pure (List.rev acc)
          else
            E.bind (fun value -> drain (remaining - 1) (value :: acc))
              (Eta.Channel.recv channel)
        in
        run
          (E.bind
             (fun () ->
               E.bind
                 (fun () ->
                   E.bind
                     (fun drained ->
                       E.bind
                         (fun recv_reason ->
                           E.map
                             (fun send_reason ->
                               (drained, recv_reason, send_reason))
                             (Eta.Channel.try_send channel 901))
                         (Eta.Channel.try_recv channel))
                     (drain (List.length values) []))
                 close)
             (List.map (Eta.Channel.send channel) values |> E.concat))
      in
      let direct = execute false in
      let effectful = execute true in
      direct.exit = effectful.exit
      && direct.events = effectful.events
      && no_pending direct
      && no_pending effectful)

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

let property_semaphore_fifo_wake =
  QCheck.Test.make
    ~name:"Semaphore wakes blocked permit waiters in FIFO order" ~count
    QCheck.(list_size (Gen.int_range 2 8) bounded_int) (fun values ->
      let semaphore = Eta.Semaphore.make ~permits:1 in
      let initially_held = Eta.Semaphore.try_acquire semaphore 1 in
      let waiting_seen = ref false in
      let waiter index value =
        E.bind
          (fun () ->
            E.bind
              (fun () ->
                E.map
                  (fun () -> value)
                  (E.sync (fun () -> Eta.Semaphore.release semaphore 1)))
              (E.log_info (Printf.sprintf "semaphore-acquired:%d" index)))
          (Eta.Semaphore.acquire semaphore 1)
      in
      let waiters = List.mapi waiter values in
      let release_initial =
        E.delay (Eta.Duration.ms 1)
          (E.sync (fun () ->
               waiting_seen := Eta.Semaphore.waiting semaphore = List.length values;
               Eta.Semaphore.release semaphore 1))
      in
      let outcome = run (E.map fst (E.par (E.all waiters) release_initial)) in
      initially_held
      && !waiting_seen
      && outcome.exit = Eta.Exit.Ok values
      && log_bodies outcome
         = List.init (List.length values) (fun index ->
               Printf.sprintf "semaphore-acquired:%d" index)
      && Eta.Semaphore.waiting semaphore = 0
      && Eta.Semaphore.available semaphore = 1
      && no_pending outcome)

let property_semaphore_validation_atomicity_and_non_barging =
  QCheck.Test.make
    ~name:"Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters"
    ~count QCheck.(quad (int_range 2 8) (int_range 1 8) nonpositive positive)
    (fun (capacity, generated_request, invalid_nonpositive, excess) ->
      let requested = min capacity generated_request in
      let invalid_over_capacity = capacity + excess in
      let semaphore = Eta.Semaphore.make ~permits:capacity in
      let creation_validation =
        raises_invalid_argument (fun () ->
            Eta.Semaphore.make ~permits:invalid_nonpositive)
      in
      let request_validation =
        raises_invalid_argument (fun () ->
            ignore
              (Eta.Semaphore.try_acquire semaphore invalid_nonpositive : bool))
        && raises_invalid_argument (fun () ->
               ignore
                 (Eta.Semaphore.try_acquire semaphore invalid_over_capacity
                   : bool))
        && raises_invalid_argument (fun () ->
               ignore (Eta.Semaphore.acquire semaphore invalid_nonpositive))
        && raises_invalid_argument (fun () ->
               ignore
                 (Eta.Semaphore.acquire semaphore invalid_over_capacity))
      in
      let release_validation =
        raises_invalid_argument (fun () ->
            Eta.Semaphore.release semaphore invalid_nonpositive)
        && raises_invalid_argument (fun () ->
               Eta.Semaphore.release semaphore excess)
        && Eta.Semaphore.available semaphore = capacity
      in
      let atomic_outcome =
        run
          (E.sync (fun () ->
               let acquired = Eta.Semaphore.try_acquire semaphore requested in
               let after_acquire = Eta.Semaphore.available semaphore in
               Eta.Semaphore.release semaphore requested;
               (acquired, after_acquire, Eta.Semaphore.available semaphore)))
      in
      let queued = Eta.Semaphore.make ~permits:capacity in
      let held = Eta.Semaphore.try_acquire queued capacity in
      let waiter =
        E.bind
          (fun () -> E.sync (fun () -> Eta.Semaphore.release queued capacity))
          (Eta.Semaphore.acquire queued capacity)
      in
      let controller =
        yields 1
          (E.sync (fun () ->
               let waiting = Eta.Semaphore.waiting queued in
               Eta.Semaphore.release queued (capacity - 1);
               let available_before_try = Eta.Semaphore.available queued in
               let barged = Eta.Semaphore.try_acquire queued 1 in
               let available_after_try = Eta.Semaphore.available queued in
               Eta.Semaphore.release queued 1;
               (waiting, available_before_try, barged, available_after_try)))
      in
      let non_barging_outcome = run (E.par waiter controller) in
      creation_validation
      && request_validation
      && release_validation
      && atomic_outcome.exit
         = Eta.Exit.Ok (true, capacity - requested, capacity)
      && no_pending atomic_outcome
      && held
      && non_barging_outcome.exit
         = Eta.Exit.Ok ((), (1, capacity - 1, false, capacity - 1))
      && Eta.Semaphore.available queued = capacity
      && Eta.Semaphore.waiting queued = 0
      && no_pending non_barging_outcome)

let permit_request = QCheck.(pair (int_range 1 8) (int_range 1 8))

let valid_permit_request (capacity, requested) =
  (capacity, min capacity requested)

let property_semaphore_with_permits_or_abort_validation_and_counters =
  QCheck.Test.make
    ~name:"Semaphore.with_permits_or_abort rejects generated invalid requests and preserves exact counters"
    ~count
    QCheck.(quad (int_range 1 8) nonpositive positive bounded_int)
    (fun (capacity, invalid_nonpositive, excess, value) ->
      let invalid_over_capacity = capacity + excess in
      let semaphore = Eta.Semaphore.make ~permits:capacity in
      let invalid request =
        raises_invalid_argument (fun () ->
            Eta.Semaphore.with_permits_or_abort semaphore request ~abort:E.never
              (fun () -> E.pure value))
      in
      let invalid_ok =
        invalid invalid_nonpositive
        && invalid invalid_over_capacity
        && Eta.Semaphore.available semaphore = capacity
        && Eta.Semaphore.waiting semaphore = 0
        && Eta.Semaphore.cancelled_waiters semaphore = 0
      in
      let acquired_outcome =
        run
          (Eta.Semaphore.with_permits_or_abort semaphore capacity ~abort:E.never
             (fun () ->
               E.sync (fun () ->
                   ( value,
                     Eta.Semaphore.available semaphore,
                     Eta.Semaphore.waiting semaphore,
                     Eta.Semaphore.cancelled_waiters semaphore ))))
      in
      let acquired_ok =
        acquired_outcome.exit = Eta.Exit.Ok (Some (value, 0, 0, 0))
        && Eta.Semaphore.available semaphore = capacity
        && Eta.Semaphore.waiting semaphore = 0
        && Eta.Semaphore.cancelled_waiters semaphore = 0
        && no_pending acquired_outcome
      in
      let aborted = Eta.Semaphore.make ~permits:capacity in
      let held = Eta.Semaphore.try_acquire aborted capacity in
      let aborted_outcome =
        run
          (Eta.Semaphore.with_permits_or_abort aborted capacity
             ~abort:(E.delay (Eta.Duration.ms 1) (E.pure value))
             (fun () -> E.pure value))
      in
      let aborted_ok =
        held
        && aborted_outcome.exit = Eta.Exit.Ok None
        && Eta.Semaphore.available aborted = 0
        && Eta.Semaphore.waiting aborted = 0
        && Eta.Semaphore.cancelled_waiters aborted = 1
        && no_pending aborted_outcome
      in
      Eta.Semaphore.release aborted capacity;
      invalid_ok && acquired_ok && aborted_ok
      && Eta.Semaphore.available aborted = capacity
      && Eta.Semaphore.waiting aborted = 0
      && Eta.Semaphore.cancelled_waiters aborted = 1)

let property_semaphore_with_permits_release_all_exits =
  QCheck.Test.make
    ~name:"Semaphore.with_permits releases on success typed failure defect and cancellation"
    ~count permit_request (fun generated ->
      let capacity, requested = valid_permit_request generated in
      List.for_all
        (fun kind ->
          let semaphore = Eta.Semaphore.make ~permits:capacity in
          let held_inside = ref false in
          let outcome =
            lifecycle_program kind (fun terminal ->
                Eta.Semaphore.with_permits semaphore requested (fun () ->
                    E.bind
                      (fun () -> terminal)
                      (E.sync (fun () ->
                           held_inside :=
                             Eta.Semaphore.available semaphore
                             = capacity - requested))))
            |> run
          in
          !held_inside
          && lifecycle_root_has_kind kind outcome.exit
          && Eta.Semaphore.available semaphore = capacity
          && Eta.Semaphore.waiting semaphore = 0
          && no_pending outcome)
        all_exit_kinds)

let property_semaphore_with_permits_or_abort_choice =
  QCheck.Test.make
    ~name:"Semaphore.with_permits_or_abort returns Some for acquisition and None for abort"
    ~count QCheck.(pair permit_request bounded_int)
    (fun (generated, value) ->
      let capacity, requested = valid_permit_request generated in
      let acquired = Eta.Semaphore.make ~permits:capacity in
      let acquired_body_ran = ref false in
      let acquired_outcome =
        run
          (Eta.Semaphore.with_permits_or_abort acquired requested ~abort:E.never
             (fun () ->
               E.sync (fun () ->
                   acquired_body_ran := true;
                   value)))
      in
      let aborted = Eta.Semaphore.make ~permits:capacity in
      let held = Eta.Semaphore.try_acquire aborted capacity in
      let aborted_body_ran = ref false in
      let aborted_outcome =
        run
          (Eta.Semaphore.with_permits_or_abort aborted requested
             ~abort:(E.delay (Eta.Duration.ms 1) (E.pure value))
             (fun () ->
               E.sync (fun () ->
                   aborted_body_ran := true;
                   value)))
      in
      let aborted_safe =
        held
        && aborted_outcome.exit = Eta.Exit.Ok None
        && not !aborted_body_ran
        && Eta.Semaphore.available aborted = 0
        && Eta.Semaphore.waiting aborted = 0
        && no_pending aborted_outcome
      in
      Eta.Semaphore.release aborted capacity;
      acquired_outcome.exit = Eta.Exit.Ok (Some value)
      && !acquired_body_ran
      && Eta.Semaphore.available acquired = capacity
      && no_pending acquired_outcome
      && aborted_safe
      && Eta.Semaphore.available aborted = capacity)

let property_semaphore_with_permits_or_abort_release_all_exits =
  QCheck.Test.make
    ~name:"Semaphore.with_permits_or_abort releases on success failure defect abort and cancellation"
    ~count QCheck.(pair permit_request bounded_int)
    (fun (generated, value) ->
      let capacity, requested = valid_permit_request generated in
      let run_owned kind =
        let semaphore = Eta.Semaphore.make ~permits:capacity in
        let held_inside = ref false in
        let body terminal =
          Eta.Semaphore.with_permits_or_abort semaphore requested ~abort:E.never
            (fun () ->
              E.bind
                (fun () -> E.map (fun () -> value) terminal)
                (E.sync (fun () ->
                     held_inside :=
                       Eta.Semaphore.available semaphore = capacity - requested)))
        in
        let outcome =
          match kind with
          | Success | Typed_failure | Defect -> run (body (direct_terminal kind))
          | Cancellation ->
              run
                (E.race
                   [
                     body E.never;
                     E.delay (Eta.Duration.ms 1) (E.pure None);
                   ])
        in
        let exit_ok =
          match kind with
          | Success -> outcome.exit = Eta.Exit.Ok (Some value)
          | Typed_failure ->
              outcome.exit = Eta.Exit.Error (Eta.Cause.Fail 17)
          | Defect -> (
              match outcome.exit with
              | Eta.Exit.Error cause -> defect_message "generated defect" cause
              | Eta.Exit.Ok _ -> false)
          | Cancellation -> outcome.exit = Eta.Exit.Ok None
        in
        !held_inside && exit_ok
        && Eta.Semaphore.available semaphore = capacity
        && Eta.Semaphore.waiting semaphore = 0
        && no_pending outcome
      in
      let owned_ok =
        List.for_all run_owned [ Success; Typed_failure; Defect; Cancellation ]
      in
      let semaphore = Eta.Semaphore.make ~permits:capacity in
      let held = Eta.Semaphore.try_acquire semaphore capacity in
      let body_ran = ref false in
      let abort_outcome =
        run
          (Eta.Semaphore.with_permits_or_abort semaphore requested
             ~abort:(E.delay (Eta.Duration.ms 1) (E.pure value))
             (fun () ->
               E.sync (fun () ->
                   body_ran := true;
                   value)))
      in
      let abort_ok =
        held
        && abort_outcome.exit = Eta.Exit.Ok None
        && not !body_ran
        && Eta.Semaphore.available semaphore = 0
        && Eta.Semaphore.waiting semaphore = 0
        && no_pending abort_outcome
      in
      Eta.Semaphore.release semaphore capacity;
      owned_ok && abort_ok && Eta.Semaphore.available semaphore = capacity)

type close_reason = Clean | Error

let close_reason =
  QCheck.make ~print:(function Clean -> "clean" | Error -> "error")
    ~shrink:(function Error -> QCheck.Iter.return Clean | Clean -> QCheck.Iter.empty)
    QCheck.Gen.(oneof_list [ Clean; Error ])

let queue_close_result = function
  | Clean -> `Closed
  | Error -> `Closed_with_error "first"

let queue_future_operations_are_closed queue reason =
  let close_result = queue_close_result reason in
  let enqueue = Eta.Queue.enqueue queue in
  let dequeue = Eta.Queue.dequeue queue in
  let failed_with_close = function
    | Eta.Exit.Error (Eta.Cause.Fail actual) -> actual = close_result
    | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false
  in
  [
    E.map failed_with_close (E.to_exit (Eta.Queue.offer queue 901));
    E.map failed_with_close (E.to_exit (Eta.Queue.offer_all queue [ 902; 903 ]));
    E.map failed_with_close (E.to_exit (Eta.Queue.send queue 904));
    E.map (( = ) close_result) (Eta.Queue.try_offer queue 905);
    E.map failed_with_close (E.to_exit (Eta.Queue.take queue));
    E.map (( = ) close_result) (Eta.Queue.poll queue);
    E.map failed_with_close (E.to_exit (Eta.Queue.take_all queue));
    E.map failed_with_close (E.to_exit (Eta.Queue.take_up_to queue ~max:0));
    E.map failed_with_close (E.to_exit (Eta.Queue.take_up_to queue ~max:3));
    E.map failed_with_close
      (E.to_exit (Eta.Queue.Enqueue.offer enqueue 911));
    E.map failed_with_close
      (E.to_exit (Eta.Queue.Enqueue.offer_all enqueue [ 912; 913 ]));
    E.map failed_with_close
      (E.to_exit (Eta.Queue.Enqueue.send enqueue 914));
    E.map (( = ) close_result) (Eta.Queue.Enqueue.try_offer enqueue 915);
    E.map failed_with_close (E.to_exit (Eta.Queue.Dequeue.take dequeue));
    E.map (( = ) close_result) (Eta.Queue.Dequeue.poll dequeue);
    E.map failed_with_close (E.to_exit (Eta.Queue.Dequeue.take_all dequeue));
    E.map failed_with_close
      (E.to_exit (Eta.Queue.Dequeue.take_up_to dequeue ~max:0));
    E.map failed_with_close
      (E.to_exit (Eta.Queue.Dequeue.take_up_to dequeue ~max:3));
  ]
  |> E.all |> E.map (List.for_all Fun.id)

let property_queue_transition_effect_wrappers =
  QCheck.Test.make
    ~name:"Queue combined and view close or shutdown effect wrappers equal direct transitions"
    ~count QCheck.(pair close_reason positive)
    (fun (reason, capacity) ->
      let run_transition make_queue transition expected_reason =
        let queue = make_queue () in
        run
          (E.bind
             (fun () ->
               E.map
                 (fun closed -> (closed, Eta.Queue.stats queue))
                 (queue_future_operations_are_closed queue expected_reason))
             (transition queue))
      in
      let same make_queue direct effectful expected_reason =
        let left = run_transition make_queue direct expected_reason in
        let right = run_transition make_queue effectful expected_reason in
        left.exit = right.exit
        && left.events = right.events
        && no_pending left && no_pending right
      in
      let direct_close queue =
        E.sync (fun () ->
            match reason with
            | Clean -> Eta.Queue.close queue
            | Error -> Eta.Queue.close_with_error queue "first")
      in
      let effect_close queue =
        match reason with
        | Clean -> Eta.Queue.close_effect queue
        | Error -> Eta.Queue.close_with_error_effect queue "first"
      in
      let direct_shutdown queue = E.sync (fun () -> Eta.Queue.shutdown queue) in
      let effect_shutdown queue = Eta.Queue.shutdown_effect queue in
      let direct_enqueue_shutdown queue =
        let enqueue = Eta.Queue.enqueue queue in
        E.sync (fun () -> Eta.Queue.Enqueue.shutdown enqueue)
      in
      let effect_enqueue_shutdown queue =
        Eta.Queue.Enqueue.shutdown_effect (Eta.Queue.enqueue queue)
      in
      let direct_dequeue_shutdown queue =
        let dequeue = Eta.Queue.dequeue queue in
        E.sync (fun () -> Eta.Queue.Dequeue.shutdown dequeue)
      in
      let effect_dequeue_shutdown queue =
        Eta.Queue.Dequeue.shutdown_effect (Eta.Queue.dequeue queue)
      in
      List.for_all
        (fun make_queue ->
          same make_queue direct_close effect_close reason
          && same make_queue direct_shutdown effect_shutdown Clean
          && same make_queue direct_enqueue_shutdown effect_enqueue_shutdown Clean
          && same make_queue direct_dequeue_shutdown effect_dequeue_shutdown Clean)
        [
          Eta.Queue.unbounded;
          (fun () -> Eta.Queue.bounded ~capacity ());
          (fun () -> Eta.Queue.dropping ~capacity ());
          (fun () -> Eta.Queue.sliding ~capacity ());
        ])

let property_queue_close =
  QCheck.Test.make ~name:"Queue graceful close/error ordering" ~count
    QCheck.(pair close_reason (list_size (Gen.int_range 0 6) bounded_int))
    (fun (reason, values) ->
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
                    (fun drained ->
                      E.map (fun fenced -> (drained, fenced))
                        (queue_future_operations_are_closed queue reason))
                    (drain (List.length values) []))
                (E.sync close))
            sends
        in
        let outcome = run program in
        outcome.exit = Eta.Exit.Ok (values, true) && no_pending outcome
      in
      let capacity = max 1 (List.length values) in
      List.for_all run_mode
        [
          Eta.Queue.unbounded;
          (fun () -> Eta.Queue.bounded ~capacity ());
          (fun () -> Eta.Queue.dropping ~capacity ());
          (fun () -> Eta.Queue.sliding ~capacity ());
        ])

let property_queue_shutdown =
  QCheck.Test.make
    ~name:"Queue shutdown immediately drops buffered values and closes future operations"
    ~count
    QCheck.(list_size (Gen.int_range 1 6) bounded_int)
    (fun values ->
      let capacity = List.length values in
      let run_mode make_queue =
        let queue = make_queue () in
        let program =
          E.bind
            (fun () ->
              E.bind
                (fun () ->
                  E.bind
                    (fun () -> queue_future_operations_are_closed queue Clean)
                    (Eta.Queue.await_shutdown queue))
                (E.sync (fun () ->
                     Eta.Queue.shutdown queue;
                     Eta.Queue.shutdown queue)))
            (List.map (Eta.Queue.send queue) values |> E.concat)
        in
        let outcome = run program in
        let stats = Eta.Queue.stats queue in
        outcome.exit = Eta.Exit.Ok true
        && stats.shutdown
        && stats.closed
        && stats.depth = 0
        && stats.sent = List.length values
        && stats.dropped = List.length values
        && Eta.Queue.is_shutdown queue
        && no_pending outcome
      in
      List.for_all run_mode
        [
          Eta.Queue.unbounded;
          (fun () -> Eta.Queue.bounded ~capacity ());
          (fun () -> Eta.Queue.dropping ~capacity ());
          (fun () -> Eta.Queue.sliding ~capacity ());
        ])

let property_queue_take_up_to_bounds =
  QCheck.Test.make
    ~name:"Queue take_up_to validates negative max and drains exactly zero or up to generated max"
    ~count
    QCheck.(triple (list_size (Gen.int_range 0 6) bounded_int) (int_range 0 8) negative)
    (fun (values, max_count, invalid_max) ->
      let rec split remaining prefix suffix =
        if remaining = 0 then (List.rev prefix, suffix)
        else
          match suffix with
          | [] -> (List.rev prefix, [])
          | value :: rest -> split (remaining - 1) (value :: prefix) rest
      in
      let expected_taken, expected_rest = split max_count [] values in
      let capacity = max 1 (List.length values) in
      let run_mode make_queue =
        let queue = make_queue () in
        let invalid =
          raises_invalid_argument (fun () ->
              ignore (Eta.Queue.take_up_to queue ~max:invalid_max))
        in
        let program =
          E.bind
            (fun () ->
              E.bind
                (fun zero ->
                  E.bind
                    (fun taken ->
                      E.map (fun rest -> (zero, taken, rest))
                        (Eta.Queue.take_all queue))
                    (Eta.Queue.take_up_to queue ~max:max_count))
                (Eta.Queue.take_up_to queue ~max:0))
            (List.map (Eta.Queue.send queue) values |> E.concat)
        in
        let outcome = run program in
        invalid
        && outcome.exit = Eta.Exit.Ok ([], expected_taken, expected_rest)
        && no_pending outcome
      in
      List.for_all run_mode
        [
          Eta.Queue.unbounded;
          (fun () -> Eta.Queue.bounded ~capacity ());
          (fun () -> Eta.Queue.dropping ~capacity ());
          (fun () -> Eta.Queue.sliding ~capacity ());
        ])

let property_queue_logical_size_and_queries =
  QCheck.Test.make
    ~name:"Queue stats size formula and empty full shutdown queries match buffered and waiting pressure"
    ~count QCheck.(pair (int_range 1 4) (int_range 1 4))
    (fun (capacity, waiter_count) ->
      let formula stats =
        stats.Eta.Queue.size
        = stats.depth - stats.waiting_receivers + stats.waiting_senders
      in
      let initial_modes =
        [
          (Eta.Queue.unbounded (), None);
          (Eta.Queue.bounded ~capacity (), Some capacity);
          (Eta.Queue.dropping ~capacity (), Some capacity);
          (Eta.Queue.sliding ~capacity (), Some capacity);
        ]
        |> List.for_all (fun (queue, expected_capacity) ->
               let outcome =
                 run
                   (E.sync (fun () ->
                        let stats = Eta.Queue.stats queue in
                        ( stats,
                          Eta.Queue.capacity queue,
                          Eta.Queue.size queue,
                          Eta.Queue.is_empty queue,
                          Eta.Queue.is_full queue,
                          Eta.Queue.is_shutdown queue )))
               in
               match outcome.exit with
               | Eta.Exit.Ok (stats, actual_capacity, size, empty, full, shutdown) ->
                   formula stats
                   && actual_capacity = expected_capacity
                   && size = 0 && empty && not full && not shutdown
                   && no_pending outcome
               | Eta.Exit.Error _ -> false)
      in
      let consumer_queue = Eta.Queue.bounded ~capacity () in
      let consumer_snapshot = ref None in
      let consumers =
        List.init waiter_count (fun _ -> E.discard (Eta.Queue.take consumer_queue))
      in
      let stop_consumers =
        yields 1
          (E.sync (fun () ->
               consumer_snapshot :=
                 Some
                   ( Eta.Queue.stats consumer_queue,
                     Eta.Queue.size consumer_queue,
                     Eta.Queue.is_empty consumer_queue,
                     Eta.Queue.is_full consumer_queue );
               Eta.Queue.shutdown consumer_queue))
      in
      let consumer_outcome = run (E.all_settled (consumers @ [ stop_consumers ])) in
      let consumers_ok =
        match !consumer_snapshot with
        | Some (stats, size, empty, full) ->
            formula stats
            && stats.depth = 0
            && stats.waiting_receivers = waiter_count
            && stats.waiting_senders = 0
            && size = -waiter_count && empty && not full
            && Eta.Queue.is_shutdown consumer_queue
            && consumer_outcome.exit
               = Eta.Exit.Ok
                   (List.init waiter_count (fun _ ->
                        Result.Error (Eta.Cause.Fail `Closed))
                   @ [ Result.Ok () ])
            && no_pending consumer_outcome
        | None -> false
      in
      let producer_queue = Eta.Queue.bounded ~capacity () in
      let producer_snapshot = ref None in
      let producers =
        List.init waiter_count (fun index ->
            E.discard (Eta.Queue.offer producer_queue (capacity + index)))
      in
      let stop_producers =
        yields 1
          (E.sync (fun () ->
               producer_snapshot :=
                 Some
                   ( Eta.Queue.stats producer_queue,
                     Eta.Queue.size producer_queue,
                     Eta.Queue.is_empty producer_queue,
                     Eta.Queue.is_full producer_queue );
               Eta.Queue.shutdown producer_queue))
      in
      let producer_outcome =
        run
          (E.bind
             (fun () -> E.all_settled (producers @ [ stop_producers ]))
             (List.init capacity (Eta.Queue.send producer_queue) |> E.concat))
      in
      let producers_ok =
        match !producer_snapshot with
        | Some (stats, size, empty, full) ->
            formula stats
            && stats.depth = capacity
            && stats.waiting_receivers = 0
            && stats.waiting_senders = waiter_count
            && size = capacity + waiter_count && not empty && full
            && Eta.Queue.is_shutdown producer_queue
            && producer_outcome.exit
               = Eta.Exit.Ok
                   (List.init waiter_count (fun _ ->
                        Result.Error (Eta.Cause.Fail `Closed))
                   @ [ Result.Ok () ])
            && no_pending producer_outcome
        | None -> false
      in
      initial_modes && consumers_ok && producers_ok)

let property_queue_shutdown_idempotence =
  QCheck.Test.make
    ~name:"Queue repeated shutdown preserves committed state counters and Closed reasons"
    ~count
    QCheck.(pair (int_range 0 3) (list_size (Gen.int_range 1 6) bounded_int))
    (fun (mode, values) ->
      let capacity = List.length values in
      let queue =
        match mode with
        | 0 -> Eta.Queue.unbounded ()
        | 1 -> Eta.Queue.bounded ~capacity ()
        | 2 -> Eta.Queue.dropping ~capacity ()
        | _ -> Eta.Queue.sliding ~capacity ()
      in
      let probe () =
        E.bind
          (fun polled ->
            E.bind
              (fun offered ->
                E.bind
                  (fun taken ->
                    E.map
                      (fun sent -> (polled, offered, taken, sent))
                      (E.to_exit (Eta.Queue.send queue 998)))
                  (E.to_exit (Eta.Queue.take queue)))
              (Eta.Queue.try_offer queue 999))
          (Eta.Queue.poll queue)
      in
      let program =
        E.bind
          (fun () ->
            E.bind
              (fun () ->
                E.bind
                  (fun first_stats ->
                    E.bind
                      (fun first_reasons ->
                        E.bind
                          (fun () ->
                            E.bind
                              (fun second_stats ->
                                E.map
                                  (fun second_reasons ->
                                    ( first_stats,
                                      first_reasons,
                                      second_stats,
                                      second_reasons ))
                                  (probe ()))
                              (E.sync (fun () -> Eta.Queue.stats queue)))
                          (E.sync (fun () -> Eta.Queue.shutdown queue)))
                      (probe ()))
                  (E.sync (fun () -> Eta.Queue.stats queue)))
              (E.sync (fun () -> Eta.Queue.shutdown queue)))
          (List.map (Eta.Queue.send queue) values |> E.concat)
      in
      let outcome = run program in
      let expected_reasons =
        ( `Closed,
          `Closed,
          Eta.Exit.Error (Eta.Cause.Fail `Closed),
          Eta.Exit.Error (Eta.Cause.Fail `Closed) )
      in
      match outcome.exit with
      | Eta.Exit.Ok
          (first_stats, first_reasons, second_stats, second_reasons) ->
          first_stats = second_stats
          && first_stats.shutdown
          && first_stats.closed
          && first_stats.depth = 0
          && first_stats.size = 0
          && first_stats.sent = List.length values
          && first_stats.received = 0
          && first_stats.dropped = List.length values
          && first_stats.waiting_senders = 0
          && first_stats.waiting_receivers = 0
          && first_stats.cancelled_senders = 0
          && first_stats.cancelled_receivers = 0
          && first_reasons = expected_reasons
          && second_reasons = expected_reasons
          && outcome.events = []
          && no_pending outcome
      | Eta.Exit.Error _ -> false)

let property_queue_shutdown_wakes_blocked_operations =
  QCheck.Test.make
    ~name:"Queue shutdown wakes blocked producer consumer and await_shutdown waiter"
    ~count QCheck.(pair bounded_int bounded_int)
    (fun (buffered, blocked_value) ->
      let producer_queue = Eta.Queue.bounded ~capacity:1 () in
      let consumer_queue = Eta.Queue.bounded ~capacity:1 () in
      let shutdown_queue = Eta.Queue.unbounded () in
      let blocked_seen = ref false in
      let await_started = ref false in
      let await_completed = ref false in
      let awaiter =
        E.bind
          (fun () ->
            E.map
              (fun () -> await_completed := true)
              (Eta.Queue.await_shutdown shutdown_queue))
          (E.bind
             (fun () -> E.sync (fun () -> await_started := true))
             (E.log_info "queue-shutdown:await-started"))
      in
      let shutdown =
        E.delay (Eta.Duration.ms 1)
          (E.sync (fun () ->
               blocked_seen :=
                 (Eta.Queue.stats producer_queue).waiting_senders = 1
                 && (Eta.Queue.stats consumer_queue).waiting_receivers = 1
                 && !await_started
                 && not !await_completed;
               Eta.Queue.shutdown producer_queue;
               Eta.Queue.shutdown consumer_queue;
               Eta.Queue.shutdown shutdown_queue))
      in
      let waiters =
        [
          Eta.Queue.send producer_queue blocked_value;
          E.discard (Eta.Queue.take consumer_queue);
          awaiter;
          shutdown;
        ]
      in
      let program =
        E.bind
          (fun () ->
            E.bind
              (fun settled ->
                E.bind
                  (fun future_take ->
                    E.map
                      (fun future_offer ->
                        (settled, future_take, future_offer))
                      (Eta.Queue.try_offer producer_queue blocked_value))
                  (Eta.Queue.poll producer_queue))
              (E.all_settled waiters))
          (Eta.Queue.send producer_queue buffered)
      in
      let outcome = run program in
      let producer_stats = Eta.Queue.stats producer_queue in
      !blocked_seen
      && !await_completed
      && outcome.exit
         = Eta.Exit.Ok
             ( [
                 Error (Eta.Cause.Fail `Closed);
                 Error (Eta.Cause.Fail `Closed);
                 Ok ();
                 Ok ();
               ],
               `Closed,
               `Closed )
      && producer_stats.depth = 0
      && producer_stats.dropped = 1
      && producer_stats.waiting_senders = 0
      && (Eta.Queue.stats consumer_queue).waiting_receivers = 0
      && log_bodies outcome = [ "queue-shutdown:await-started" ]
      && outcome.sleeps = [ Eta.Duration.ms 1 ]
      && no_pending outcome)

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
          if List.length delays <> length then false
          else monotone delays && no_pending outcome)

let terminal_schedule_summary schedule =
  let rec loop continues driver =
    match Eta.Schedule.step ~now_ms:continues ~input:() driver with
    | Eta.Schedule.Continue _, next -> loop (continues + 1) next
    | Eta.Schedule.Done metadata, _ -> (continues, metadata.delay)
  in
  loop 0 (Eta.Schedule.start schedule)

let property_schedule_done_delay_zero =
  QCheck.Test.make
    ~name:"Schedule terminal Done metadata delay is exactly Duration.zero"
    ~count
    QCheck.(triple (int_range 0 2) (int_range 0 8) (int_range 0 8))
    (fun (shape, left_length, right_length) ->
      let expected_continues, summary =
        match shape with
        | 0 ->
            (left_length, terminal_schedule_summary (Eta.Schedule.recurs left_length))
        | 1 ->
            ( left_length,
              terminal_schedule_summary
                (Eta.Schedule.forever
                |> Eta.Schedule.while_output (fun output ->
                       output < left_length)) )
        | _ ->
            ( left_length + right_length,
              terminal_schedule_summary
                (Eta.Schedule.and_then
                   (Eta.Schedule.recurs left_length)
                   (Eta.Schedule.recurs right_length)) )
      in
      let outcome = run (E.sync (fun () -> summary)) in
      outcome.exit = Eta.Exit.Ok (expected_continues, Eta.Duration.zero)
      && outcome.events = []
      && no_pending outcome)

let property_schedule_and_then_phase_tags =
  QCheck.Test.make
    ~name:"Schedule.and_then tags every first phase output before every second phase output"
    ~count QCheck.(pair (int_range 0 8) (int_range 0 8))
    (fun (first_length, second_length) ->
      let collect () =
        let rec loop driver acc =
          match Eta.Schedule.step ~now_ms:0 ~input:() driver with
          | Eta.Schedule.Continue metadata, next ->
              loop next (metadata.output :: acc)
          | Eta.Schedule.Done metadata, _ ->
              List.rev (metadata.output :: acc)
        in
        Eta.Schedule.and_then
          (Eta.Schedule.recurs first_length)
          (Eta.Schedule.recurs second_length)
        |> Eta.Schedule.start |> fun driver -> loop driver []
      in
      let expected =
        List.init first_length (fun output -> Eta.Schedule.First_phase output)
        @ List.init (second_length + 1) (fun output ->
              Eta.Schedule.Second_phase output)
      in
      let outcome = run (E.sync collect) in
      outcome.exit = Eta.Exit.Ok expected
      && outcome.events = []
      && no_pending outcome)

let property_schedule_tap_input_order_and_retry_state =
  QCheck.Test.make
    ~name:"Schedule.tap_input precedes each step and abandoned Hook retry preserves driver state"
    ~count QCheck.(pair (int_range 0 8) bounded_int)
    (fun (recurrences, input_base) ->
      let observe () =
        let schedule =
          Eta.Schedule.recurs recurrences
          |> Eta.Schedule.tap_input Fun.id
        in
        let initial = Eta.Schedule.start schedule in
        match Eta.Schedule.step_plan ~now_ms:0 ~input:input_base initial with
        | Eta.Schedule.Complete _ -> None
        | Eta.Schedule.Hook (abandoned_hook, _abandoned_resume) ->
            let rec drive output_index driver acc =
              let input = input_base + output_index + 1 in
              match Eta.Schedule.step_plan ~now_ms:output_index ~input driver with
              | Eta.Schedule.Complete _ -> None
              | Eta.Schedule.Hook (hook, resume) -> (
                  let acc = `Input_hook hook :: acc in
                  match resume () with
                  | Eta.Schedule.Hook _ -> None
                  | Eta.Schedule.Complete (decision, next) ->
                      let metadata, status =
                        match decision with
                        | Eta.Schedule.Continue metadata -> (metadata, `Continue)
                        | Eta.Schedule.Done metadata -> (metadata, `Done)
                      in
                      let acc =
                        `Inner_step
                          ( metadata.input,
                            metadata.output,
                            metadata.attempt,
                            status )
                        :: acc
                      in
                      if status = `Done then Some (List.rev acc)
                      else drive (output_index + 1) next acc)
            in
            drive 0 initial [ `Abandoned_hook abandoned_hook ]
      in
      let expected =
        `Abandoned_hook input_base
        :: List.concat_map
             (fun output ->
               let input = input_base + output + 1 in
               let status = if output < recurrences then `Continue else `Done in
               [
                 `Input_hook input;
                 `Inner_step (input, output, output + 1, status);
               ])
             (List.init (recurrences + 1) Fun.id)
      in
      let outcome = run (E.sync observe) in
      outcome.exit = Eta.Exit.Ok (Some expected)
      && outcome.events = []
      && no_pending outcome)

let property_schedule_tap_output_includes_done =
  QCheck.Test.make
    ~name:"Schedule.tap_output runs after every produced output including terminal Done"
    ~count QCheck.(int_range 0 8) (fun recurrences ->
      let observe () =
        let schedule =
          Eta.Schedule.recurs recurrences
          |> Eta.Schedule.tap_output Fun.id
        in
        let rec loop driver acc =
          match Eta.Schedule.step_plan ~now_ms:0 ~input:() driver with
          | Eta.Schedule.Complete _ -> None
          | Eta.Schedule.Hook (hook_output, resume) -> (
              match resume () with
              | Eta.Schedule.Hook _ -> None
              | Eta.Schedule.Complete (decision, next) ->
                  let metadata, status =
                    match decision with
                    | Eta.Schedule.Continue metadata -> (metadata, `Continue)
                    | Eta.Schedule.Done metadata -> (metadata, `Done)
                  in
                  let acc = (hook_output, metadata.output, status) :: acc in
                  if status = `Done then Some (List.rev acc) else loop next acc)
        in
        loop (Eta.Schedule.start schedule) []
      in
      let expected =
        List.init (recurrences + 1) (fun output ->
            ( output,
              output,
              if output < recurrences then `Continue else `Done ))
      in
      let outcome = run (E.sync observe) in
      outcome.exit = Eta.Exit.Ok (Some expected)
      && outcome.events = []
      && no_pending outcome)

let schedule_metadata_equal left right =
  left.Eta.Schedule.input = right.Eta.Schedule.input
  && left.output = right.output
  && left.attempt = right.attempt
  && left.start_ms = right.start_ms
  && left.now_ms = right.now_ms
  && Eta.Duration.equal left.elapsed right.elapsed
  && Eta.Duration.equal left.elapsed_since_previous right.elapsed_since_previous
  && Eta.Duration.equal left.delay right.delay

let property_schedule_next_continue_only =
  QCheck.Test.make
    ~name:"Schedule.next returns Some exactly for Continue and None exactly for terminal Done"
    ~count QCheck.(pair (int_range 0 12) (int_range 0 100))
    (fun (recurrences, start_ms) ->
      let compare () =
        let rec loop index step_driver next_driver some_count =
          let now_ms = start_ms + index in
          match
            ( Eta.Schedule.step ~now_ms ~input:index step_driver,
              Eta.Schedule.next ~now_ms ~input:index next_driver )
          with
          | (Eta.Schedule.Continue step_metadata, step_next),
            Some (next_metadata, next_next) ->
              if schedule_metadata_equal step_metadata next_metadata then
                loop (index + 1) step_next next_next (some_count + 1)
              else (false, some_count, 0)
          | (Eta.Schedule.Done _, _), None -> (true, some_count, 1)
          | (Eta.Schedule.Continue _, _), None
          | (Eta.Schedule.Done _, _), Some _ ->
              (false, some_count, 0)
        in
        let schedule = Eta.Schedule.recurs recurrences in
        loop 0 (Eta.Schedule.start schedule) (Eta.Schedule.start schedule) 0
      in
      let outcome = run (E.sync compare) in
      outcome.exit = Eta.Exit.Ok (true, recurrences, 1)
      && outcome.events = []
      && no_pending outcome)

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
            let expected_outer_now = if kind = Cancellation then 1 else 0 in
            match outcome.exit with
            | Eta.Exit.Ok (scoped_exit, after_now) ->
                expected_scoped_exit (kind, scoped_exit)
                && after_now = expected_outer_now
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
                   && record.ts_ms = if kind = Cancellation then 1 else 0
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

let property_nested_clock_override =
  QCheck.Test.make
    ~name:"nested clock override uses innermost binding and restores each exact outer clock"
    ~count QCheck.(pair (int_range 10 100) (int_range 101 1000))
    (fun (outer_now, inner_now) ->
      let read name =
        E.bind
          (fun now -> E.map (fun () -> now) (E.log_info name))
          E.now_ms
      in
      let nested =
        E.bind
          (fun outer_before ->
            E.bind
              (fun inner ->
                E.map
                  (fun outer_after -> (outer_before, inner, outer_after))
                  (read "nested-clock:outer-after"))
              (E.with_clock (fixed_clock inner_now)
                 (read "nested-clock:inner")))
          (read "nested-clock:outer-before")
        |> E.with_clock (fixed_clock outer_now)
      in
      let outcome =
        run
          (E.bind
             (fun (outer_before, inner, outer_after) ->
               E.map
                 (fun base_after ->
                   (outer_before, inner, outer_after, base_after))
                 (read "nested-clock:base-after"))
             nested)
      in
      outcome.exit = Eta.Exit.Ok (outer_now, inner_now, outer_now, 0)
      && List.map
           (fun record -> (record.Eta.Logger.body, record.ts_ms))
           outcome.logs
         = [
             ("nested-clock:outer-before", outer_now);
             ("nested-clock:inner", inner_now);
             ("nested-clock:outer-after", outer_now);
             ("nested-clock:base-after", 0);
           ]
      && no_pending outcome)

let span_trace_fingerprints spans =
  List.map
    (fun span -> (span.Eta.Tracer.name, span.trace_id))
    spans

let property_nested_observability_random_override =
  QCheck.Test.make
    ~name:"nested random logger and tracer overrides use innermost bindings and restore exact outer observations"
    ~count QCheck.(pair (int_range 0 1000) (int_range 1001 2000))
    (fun (outer_seed, inner_seed) ->
      let outer_names = [ "nested-cap:outer-before"; "nested-cap:outer-after" ] in
      let inner_name = "nested-cap:inner" in
      let base_name = "nested-cap:base-after" in
      let reference seed names =
        let tracer = Eta.Tracer.in_memory () in
        let outcome =
          List.map (fun name -> E.named name E.unit) names |> E.concat
          |> E.with_random (Eta.Capabilities.random_of_seed seed)
          |> E.with_tracer (Eta.Tracer.as_capability tracer)
          |> run
        in
        (span_trace_fingerprints (Eta.Tracer.dump tracer), outcome)
      in
      let expected_outer, outer_reference = reference outer_seed outer_names in
      let expected_inner, inner_reference = reference inner_seed [ inner_name ] in
      let base_reference = run (E.named base_name E.unit) in
      let outer_logger = Eta.Logger.in_memory () in
      let inner_logger = Eta.Logger.in_memory () in
      let outer_tracer = Eta.Tracer.in_memory () in
      let inner_tracer = Eta.Tracer.in_memory () in
      let probe name =
        E.bind (fun () -> E.named name E.unit) (E.log_info name)
      in
      let inner =
        probe inner_name
        |> E.with_random (Eta.Capabilities.random_of_seed inner_seed)
        |> E.with_logger (Eta.Logger.as_capability inner_logger)
        |> E.with_tracer (Eta.Tracer.as_capability inner_tracer)
      in
      let outer =
        E.concat [ probe (List.hd outer_names); inner; probe (List.hd (List.tl outer_names)) ]
        |> E.with_random (Eta.Capabilities.random_of_seed outer_seed)
        |> E.with_logger (Eta.Logger.as_capability outer_logger)
        |> E.with_tracer (Eta.Tracer.as_capability outer_tracer)
      in
      let outcome = run (E.bind (fun () -> probe base_name) outer) in
      outcome.exit = Eta.Exit.Ok ()
      && log_bodies outcome = [ base_name ]
      && List.map (fun record -> record.Eta.Logger.body) (Eta.Logger.dump outer_logger)
         = outer_names
      && List.map (fun record -> record.Eta.Logger.body) (Eta.Logger.dump inner_logger)
         = [ inner_name ]
      && span_trace_fingerprints (Eta.Tracer.dump outer_tracer) = expected_outer
      && span_trace_fingerprints (Eta.Tracer.dump inner_tracer) = expected_inner
      && span_trace_fingerprints outcome.spans
         = span_trace_fingerprints base_reference.spans
      && no_pending outer_reference
      && no_pending inner_reference
      && no_pending base_reference
      && no_pending outcome)

let property_log_pipeline =
  QCheck.Test.make
    ~name:"log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink"
    ~count QCheck.(triple bounded_int bounded_int bounded_int)
    (fun (outer_value, inner_value, call_value) ->
      let transform_calls = ref 0 in
      let attrs_seen = ref [] in
      let transform record =
        incr transform_calls;
        attrs_seen := record.Eta.Logger.attrs;
        E.Replace { record with body = "transformed" }
      in
      let program =
        E.bind
          (fun () -> E.log_warn ~attrs:[ ("call", string_of_int call_value) ] "kept")
          (E.log_info "filtered")
        |> E.intercept_log transform
        |> E.annotate_logs [ ("inner", string_of_int inner_value) ]
        |> E.with_minimum_log_level Eta.Capabilities.Warn
        |> E.annotate_logs [ ("outer", string_of_int outer_value) ]
        |> E.with_minimum_log_level Eta.Capabilities.Info
      in
      let outcome = run program in
      let expected_attrs =
        [
          ("outer", string_of_int outer_value);
          ("inner", string_of_int inner_value);
          ("call", string_of_int call_value);
        ]
      in
      !transform_calls = 1
      && !attrs_seen = expected_attrs
      && (match outcome.logs with
         | [ record ] -> record.body = "transformed" && record.attrs = expected_attrs
         | _ -> false)
      && (match outcome.events with [ Run.Log _ ] -> true | _ -> false)
      && no_pending outcome)

let property_nested_log_interceptor_order =
  QCheck.Test.make
    ~name:"nested log interceptors run outermost first and pass replacements inward"
    ~count bounded_int (fun tag ->
      let calls = ref [] in
      let outer (record : Eta.Logger.record) =
        calls := !calls @ [ "outer" ];
        E.Replace
          {
            record with
            Eta.Logger.body = record.body ^ Printf.sprintf ":outer:%d" tag;
          }
      in
      let inner (record : Eta.Logger.record) =
        calls := !calls @ [ "inner" ];
        E.Replace { record with Eta.Logger.body = record.body ^ ":inner" }
      in
      let outcome =
        run
          (E.intercept_log outer
             (E.intercept_log inner (E.log_info "intercepted")))
      in
      !calls = [ "outer"; "inner" ]
      && log_bodies outcome
         = [ Printf.sprintf "intercepted:outer:%d:inner" tag ]
      && no_pending outcome)

let short_int_list = QCheck.(list_size (Gen.int_range 0 3) bounded_int)
let log_interceptor_shape = QCheck.(pair bounded_int short_int_list)

let log_interceptor_shapes =
  QCheck.(list_size (Gen.int_range 0 3) log_interceptor_shape)

let log_drop_case =
  QCheck.(quad bounded_int short_int_list log_interceptor_shapes log_interceptor_shapes)

let property_log_interceptor_drop =
  QCheck.Test.make
    ~name:"log interceptor Drop executes exactly its generated outer prefix and skips its suffix and sink"
    ~count log_drop_case
    (fun (body_shape, initial_attr_shapes, outer_shapes, inner_shapes) ->
      let drop_position = List.length outer_shapes in
      let interceptor_shapes = outer_shapes @ [ (0, []) ] @ inner_shapes in
      let depth = List.length interceptor_shapes in
      let calls = Array.make depth 0 in
      let records_seen = ref [] in
      let attrs label values =
        List.mapi
          (fun index value ->
            (Printf.sprintf "%s-%d" label index, string_of_int value))
          values
      in
      let initial_body = Printf.sprintf "body:%d" body_shape in
      let initial_attrs = attrs "initial" initial_attr_shapes in
      let interceptors =
        List.mapi
          (fun position (body_shape, attr_shapes) record ->
            calls.(position) <- calls.(position) + 1;
            records_seen :=
              !records_seen @ [ (record.Eta.Logger.body, record.attrs) ];
            if position = drop_position then E.Drop
            else
              E.Replace
                {
                  record with
                  Eta.Logger.body =
                    record.body ^ Printf.sprintf ":interceptor:%d" body_shape;
                  attrs =
                    record.attrs
                    @ attrs (Printf.sprintf "interceptor-%d" position) attr_shapes;
                })
          interceptor_shapes
      in
      let program =
        List.fold_right E.intercept_log interceptors
          (E.log_info ~attrs:initial_attrs initial_body)
      in
      let outcome = run program in
      let rec expected_model position body attrs_seen =
        if position = depth then ([], Some (body, attrs_seen))
        else
          let current = (body, attrs_seen) in
          if position = drop_position then ([ current ], None)
          else
            let body_shape, attr_shapes =
              List.nth interceptor_shapes position
            in
            let suffix_seen, sink =
              expected_model (position + 1)
                (body ^ Printf.sprintf ":interceptor:%d" body_shape)
                (attrs_seen
                @ attrs (Printf.sprintf "interceptor-%d" position) attr_shapes)
            in
            (current :: suffix_seen, sink)
      in
      let expected_seen, expected_sink =
        expected_model 0 initial_body initial_attrs
      in
      let expected_calls =
        Array.init depth (fun position ->
            if position <= drop_position then 1 else 0)
      in
      let sink_matches =
        match (expected_sink, outcome.logs) with
        | None, [] -> true
        | Some (body, attrs), [ record ] ->
            record.Eta.Logger.body = body && record.attrs = attrs
        | None, _ | Some _, _ -> false
      in
      Array.to_list calls = Array.to_list expected_calls
      && !records_seen = expected_seen
      && outcome.exit = Eta.Exit.Ok ()
      && sink_matches
      && (match (expected_sink, outcome.events) with
         | None, [] | Some _, [ Run.Log _ ] -> true
         | None, _ | Some _, _ -> false)
      && no_pending outcome)

let laws =
  [
    property_map_identity;
    property_map_composition;
    property_bind_associativity;
    property_bind_left_identity;
    property_bind_right_identity;
    property_bind_error_left_identity;
    property_bind_error_once_and_first_typed;
    property_bind_error_uncatchable_boundary;
    property_fold_coherence;
    property_par_pair_order;
    property_par_fail_fast;
    property_map_par_order;
    property_map_par_fail_fast;
    property_map_par_max_concurrent;
    property_all_input_order;
    property_all_fail_fast;
    property_all_settled_input_order_and_capture;
    property_race_first_value;
    property_race_loser_cancellation;
    property_finally_exactly_once;
    property_finally_cleanup_failure_after_success;
    property_finally_cleanup_failure_suppressed;
    property_scope_lifo;
    property_nested_scope_release_boundary;
    property_with_scope_release_all_exits;
    property_with_resource_all_exits;
    property_with_resource_release_failure_after_success;
    property_acquire_use_release_failure_suppressed;
    property_channel_blocked_sender_fifo;
    property_channel_capacity_validation;
    property_channel_blocking_boundaries;
    property_channel_blocked_sender_cancellation;
    property_channel_try_boundaries;
    property_channel_close;
    property_channel_close_effect_wrappers;
    property_semaphore_cancellation;
    property_semaphore_fifo_wake;
    property_semaphore_validation_atomicity_and_non_barging;
    property_semaphore_with_permits_or_abort_validation_and_counters;
    property_semaphore_with_permits_release_all_exits;
    property_semaphore_with_permits_or_abort_choice;
    property_semaphore_with_permits_or_abort_release_all_exits;
    property_queue_transition_effect_wrappers;
    property_queue_close;
    property_queue_shutdown;
    property_queue_take_up_to_bounds;
    property_queue_logical_size_and_queries;
    property_queue_shutdown_idempotence;
    property_queue_shutdown_wakes_blocked_operations;
    property_schedule_monotone;
    property_schedule_done_delay_zero;
    property_schedule_and_then_phase_tags;
    property_schedule_tap_input_order_and_retry_state;
    property_schedule_tap_output_includes_done;
    property_schedule_next_continue_only;
    property_recurs_count;
    property_override_restoration;
    property_override_sibling_isolation;
    property_nested_clock_override;
    property_nested_observability_random_override;
    property_log_pipeline;
    property_nested_log_interceptor_order;
    property_log_interceptor_drop;
  ]

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed laws
  in
  exit code
