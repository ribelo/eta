module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  type law_deps = {
    add : int -> int;
    mul : int -> int;
  }

  type law_err = [ `E0 | `E1 | `Neg | `Retry | `Release | `Timeout ]
  type packed_law_schedule =
    | Pack :
        (law_err, 'output, (unit, law_err) Effect.t) Schedule.t
        -> packed_law_schedule

  let pp_law_err fmt = function
    | `E0 -> Format.pp_print_string fmt "E0"
    | `E1 -> Format.pp_print_string fmt "E1"
    | `Neg -> Format.pp_print_string fmt "Neg"
    | `Retry -> Format.pp_print_string fmt "Retry"
    | `Release -> Format.pp_print_string fmt "Release"
    | `Timeout -> Format.pp_print_string fmt "Timeout"

  let equal_law_err (a : law_err) (b : law_err) = a = b

  let pp_hidden ppf _ = Format.pp_print_string ppf "<properties>"

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

  let with_law_runtime f =
    B.with_runtime @@ fun _ctx rt ->
    let deps = { add = (fun n -> n + 1); mul = (fun n -> n * 2) } in
    f rt deps

  let check_law rt name left right =
    let left_exit = B.run rt left in
    let right_exit = B.run rt right in
    if not (Exit.equal Int.equal equal_law_err left_exit right_exit) then
      Alcotest.failf "%s failed:@.left:  %a@.right: %a" name
        (Exit.pp Format.pp_print_int pp_law_err)
        left_exit
        (Exit.pp Format.pp_print_int pp_law_err)
        right_exit

  let law_effects deps : (int, law_err) Effect.t list =
    [
      Effect.pure (-2);
      Effect.pure 0;
      Effect.pure 3;
      Effect.fail `E0;
      Effect.fail `E1;
      Effect.named "law.add" (Effect.sync (fun () -> deps.add 1));
      Effect.named "law.mul" (Effect.sync (fun () -> deps.mul 2));
      Effect.pure 2 |> Effect.map (fun n -> n + 4);
      Effect.pure 3 |> Effect.bind (fun n -> Effect.pure (n * 3));
      Effect.fail `E0 |> Effect.bind_error (fun `E0 -> Effect.pure 7);
    ]

  let law_functions deps : (string * (int -> (int, law_err) Effect.t)) list =
    [
      ("inc", fun x -> Effect.pure (x + 1));
      ( "fail-negative",
        fun x -> if x < 0 then Effect.fail `Neg else Effect.pure (x * 2) );
      ("deps-add", fun x -> Effect.named "law.f.add" (Effect.sync (fun () -> deps.add x)));
      ("mapped", fun x -> Effect.pure x |> Effect.map (fun n -> n + 3));
      ( "catch-local",
        fun x -> Effect.fail `E0 |> Effect.bind_error (fun `E0 -> Effect.pure (x + 5)) );
    ]

  let test_properties_monad_laws () =
    with_law_runtime @@ fun rt deps ->
    let values = [ -2; 0; 3 ] in
    let effects = law_effects deps in
    let functions = law_functions deps in
    List.iter
      (fun x ->
        List.iter
          (fun (fname, f) ->
            check_law rt
              (Printf.sprintf "left identity x=%d f=%s" x fname)
              (Effect.bind f (Effect.pure x))
              (f x))
          functions)
      values;
    List.iteri
      (fun i m ->
        check_law rt
          (Printf.sprintf "right identity m=%d" i)
          (Effect.bind Effect.pure m) m)
      effects;
    List.iteri
      (fun i m ->
        List.iter
          (fun (fname, f) ->
            List.iter
              (fun (gname, g) ->
                check_law rt
                  (Printf.sprintf "associativity m=%d f=%s g=%s" i fname gname)
                  (Effect.bind g (Effect.bind f m))
                  (Effect.bind (fun x -> Effect.bind g (f x)) m))
              functions)
          functions)
      effects

  let catch_handler : law_err -> (int, law_err) Effect.t = function
    | `E0 -> Effect.pure 10
    | `E1 -> Effect.pure 20
    | `Neg -> Effect.pure 30
    | `Retry -> Effect.pure 40
    | `Release -> Effect.pure 50
    | `Timeout -> Effect.pure 60

  let test_properties_catch_laws () =
    with_law_runtime @@ fun rt deps ->
    List.iter
      (fun x ->
        check_law rt
          (Printf.sprintf "catch pure identity x=%d" x)
          (Effect.bind_error catch_handler (Effect.pure x))
          (Effect.pure x))
      [ -2; 0; 3 ];
    List.iter
      (fun err ->
        check_law rt "catch fail identity"
          (Effect.bind_error catch_handler (Effect.fail err))
          (catch_handler err))
      ([ `E0; `E1; `Neg; `Retry; `Release; `Timeout ] : law_err list);
    List.iter
      (fun err ->
        List.iter
          (fun (_fname, f) ->
            check_law rt "catch handles bind source failure"
              (Effect.bind_error catch_handler (Effect.bind f (Effect.fail err)))
              (catch_handler err))
          (law_functions deps))
      ([ `E0; `E1; `Neg ] : law_err list);
    List.iter
      (fun x ->
        check_law rt "catch handles continuation failure"
          (Effect.bind_error catch_handler
             (Effect.bind (fun _ -> Effect.fail `E1) (Effect.pure x)))
          (catch_handler `E1))
      [ -2; 0; 3 ]

  let test_properties_race_success_invariant () =
    with_law_runtime @@ fun rt _deps ->
    let cases =
      [
        ("ok1", Effect.pure 1);
        ("ok2", Effect.pure 2);
        ("fail0", Effect.fail `E0);
        ("fail1", Effect.fail `E1);
      ]
    in
    let succeeds = function Exit.Ok _ -> true | Exit.Error _ -> false in
    List.iter
      (fun (an, a) ->
        List.iter
          (fun (bn, b) ->
            let actual = B.run rt (Effect.race [ a; b ]) |> succeeds in
            let expected =
              B.run rt a |> succeeds || (B.run rt b |> succeeds)
            in
            Alcotest.(check bool)
              (Printf.sprintf "race success iff any succeeds %s/%s" an bn)
              expected actual)
          cases)
      cases

  let test_properties_retry_and_repeat_laws () =
    with_law_runtime @@ fun rt _deps ->
    let schedules =
      [
        Pack (Schedule.recurs 0);
        Pack (Schedule.recurs 3);
        Pack (Schedule.both (Schedule.recurs 3) (Schedule.spaced Duration.zero));
        Pack (Schedule.either (Schedule.recurs 2) (Schedule.recurs 4));
      ]
    in
    List.iteri
      (fun i (Pack schedule) ->
        let attempts = ref 0 in
        let attempt =
          Effect.named "retry.always-succeed" (Effect.sync (fun () ->
              incr attempts;
              i))
        in
        Alcotest.(check int)
          (Printf.sprintf "retry success result %d" i)
          i
          (run_ok rt (Effect.retry ~schedule:schedule ~while_:(fun (_ : law_err) -> true) attempt));
        Alcotest.(check int)
          (Printf.sprintf "retry success attempts %d" i)
          1 !attempts)
      schedules;
    List.iter
      (fun n ->
        let ticks = ref 0 in
        ignore
          (run_ok rt
             (Effect.repeat ~schedule:(Schedule.recurs n)
                (Effect.named "repeat.tick"
                   (Effect.sync (fun () -> incr ticks))))
            : int);
        Alcotest.(check int)
          (Printf.sprintf "repeat recurs %d runs initial+n" n)
          (n + 1) !ticks)
      [ 0; 1; 2; 5 ]

  let test_properties_scope_finalizers_success_failure_once () =
    B.with_runtime @@ fun _ctx rt ->
    let run_case body =
      let releases = ref [] in
      let resource name =
        Effect.acquire_release
          ~acquire:(Effect.named ("acquire." ^ name) (Effect.sync (fun () -> ())))
          ~release:(fun () ->
            Effect.named ("release." ^ name) (Effect.sync (fun () ->
                releases := name :: !releases)))
      in
      ignore
        (B.run rt
           (Effect.scoped
              (Effect.concat [ resource "a"; resource "b"; body ])));
      List.sort String.compare !releases
    in
    Alcotest.(check (list string))
      "success releases once" [ "a"; "b" ] (run_case Effect.unit);
    Alcotest.(check (list string))
      "typed failure releases once" [ "a"; "b" ]
      (run_case (Effect.fail `E0))

  let test_properties_scope_cancelled_finalizer_once () =
    B.with_test_clock @@ fun ctx _clock rt ->
    let releases = ref 0 in
    let acquired, acquired_u = B.create_promise () in
    let resource =
      Effect.acquire_release
        ~acquire:
          (Effect.named "acquire.cancelled"
             (Effect.sync (fun () -> B.resolve acquired_u ())))
        ~release:(fun () ->
          Effect.named "release.cancelled"
            (Effect.sync (fun () -> incr releases)))
    in
    let slow =
      Effect.scoped
        (resource
        |> Effect.bind (fun () ->
               Effect.pure "slow" |> Effect.delay (Duration.seconds 10)))
    in
    let fast =
      Effect.named "wait-acquired" (B.await_effect acquired)
      |> Effect.map (fun () -> "fast")
    in
    let promise = B.fork_run ctx rt (Effect.race [ slow; fast ]) in
    (match B.await promise with
    | Exit.Ok "fast" -> ()
    | Exit.Ok other -> Alcotest.failf "expected fast winner, got %s" other
    | Exit.Error cause ->
        Alcotest.failf "expected fast winner, got %a" (Cause.pp pp_hidden)
          cause);
    Alcotest.(check int) "cancelled release once" 1 !releases

  let tests =
    [
      ( "Properties",
        [
          Alcotest.test_case "monad laws" `Quick test_properties_monad_laws;
          Alcotest.test_case "catch laws" `Quick test_properties_catch_laws;
          Alcotest.test_case "race success invariant" `Quick
            test_properties_race_success_invariant;
          Alcotest.test_case "retry and repeat laws" `Quick
            test_properties_retry_and_repeat_laws;
          Alcotest.test_case "scope finalizers success/failure once" `Quick
            test_properties_scope_finalizers_success_failure_once;
          Alcotest.test_case "scope cancelled finalizer once" `Quick
            test_properties_scope_cancelled_finalizer_once;
        ] );
    ]
end
