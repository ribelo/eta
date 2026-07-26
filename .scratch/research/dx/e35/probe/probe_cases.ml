open Eta

type runnable =
  | Run :
      ('a, 'err) Effect.t * (('a, 'err) Exit.t -> (unit, string) result)
      -> runnable

type prepared = Effect of runnable | Synchronous of (unit -> (unit, string) result)

let cases =
  [
    "dynamic_bind";
    "static_map";
    "concat";
    "bind_error";
    "cause_sequential";
    "cause_concurrent";
  ]

let check_depth depth =
  if depth < 0 then Error "depth must be non-negative" else Ok ()

let expect_int expected = function
  | Exit.Ok actual when actual = expected -> Ok ()
  | Exit.Ok actual ->
      Error (Printf.sprintf "expected successful value %d, got %d" expected actual)
  | Exit.Error cause ->
      Error
        (Format.asprintf "expected success, got %a"
           (Cause.pp (fun fmt (_ : [ `Boom ]) -> Format.pp_print_string fmt "Boom"))
           cause)

let expect_unit = function
  | Exit.Ok () -> Ok ()
  | Exit.Error cause ->
      Error
        (Format.asprintf "expected success, got %a"
           (Cause.pp (fun fmt (_ : [ `Boom ]) -> Format.pp_print_string fmt "Boom"))
           cause)

let dynamic_bind depth =
  let rec next remaining value =
    if remaining = 0 then Effect.pure value
    else
      Effect.bind
        (fun value -> next (remaining - 1) (value + 1))
        (Effect.pure value)
  in
  Run (next depth 0, expect_int depth)

let static_map depth =
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Effect.map (fun value -> value + 1) acc)
  in
  Run (build depth (Effect.pure 0), expect_int depth)

let concat depth =
  let rec build remaining acc =
    if remaining = 0 then acc else build (remaining - 1) (Effect.unit :: acc)
  in
  Run (Effect.concat (build depth []), expect_unit)

let bind_error depth =
  let handled = ref 0 in
  let recover (_ : [ `Boom ]) =
    incr handled;
    Effect.fail `Boom
  in
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Effect.bind_error recover acc)
  in
  let verify = function
    | Exit.Error (Cause.Fail `Boom) when !handled = depth -> Ok ()
    | Exit.Error (Cause.Fail `Boom) ->
        Error
          (Printf.sprintf "expected %d recovery handlers, observed %d" depth
             !handled)
    | Exit.Ok () -> Error "expected the recovery chain to retain typed failure"
    | Exit.Error cause ->
        Error
          (Format.asprintf "unexpected recovery cause: %a"
             (Cause.pp (fun fmt `Boom -> Format.pp_print_string fmt "Boom"))
             cause)
  in
  Run (build depth (Effect.fail `Boom), verify)

let cause_tree combine depth () =
  let cause = ref (Cause.fail 0) in
  for value = 1 to depth do
    cause := combine [ !cause; Cause.fail value ]
  done;
  let failures = Cause.failures !cause in
  let expected = depth + 1 in
  match (List.length failures, failures) with
  | actual, first :: _ when actual = expected && first = 0 -> Ok ()
  | actual, _ ->
      Error
        (Printf.sprintf
           "expected %d failures in left-to-right order from zero, got %d"
           expected actual)

let prepare name depth =
  match check_depth depth with
  | Error _ as error -> error
  | Ok () -> (
      match name with
      | "dynamic_bind" -> Ok (Effect (dynamic_bind depth))
      | "static_map" -> Ok (Effect (static_map depth))
      | "concat" -> Ok (Effect (concat depth))
      | "bind_error" -> Ok (Effect (bind_error depth))
      | "cause_sequential" ->
          Ok (Synchronous (cause_tree Cause.sequential depth))
      | "cause_concurrent" ->
          Ok (Synchronous (cause_tree Cause.concurrent depth))
      | unknown -> Error (Printf.sprintf "unknown case %S" unknown))

let stack_overflow_in_cause cause =
  List.exists
    (fun (die : Cause.die) -> die.Cause.exn = Stack_overflow)
    (Cause.defects cause)
