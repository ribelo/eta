module Crux = Eta_crux
module Observer = Eta_crux_test.Post_commit_effect_observer

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let start runtime post_commit =
  ignore
    (run_ok runtime
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
              Invalid_argument "post-commit already started")))

let committed runtime root =
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Committed committed) ->
      start runtime committed.post_commit;
      committed.output
  | _ -> Alcotest.fail "expected committed reset advancement"

let send runtime endpoint action =
  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint action
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "ingress closed")))

let reset runtime authority =
  ignore
    (run_ok runtime
       (Crux.Reset.trigger authority
       |> Eta.Effect.or_die (fun _ ->
              Invalid_argument "reset ingress closed")))

let test_reset_snapshot_atomicity_and_effect_inventory () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let left_seen = ref [] in
  let right_seen = ref [] in
  let left_effects = ref 0 in
  let right_effects = ref 0 in
  let description =
    Crux.Reset.scope (Crux.return 2)
      ~f:(fun ~reset ~input ->
        let left =
          Crux.State_machine.create input ~default_model:1
            ~reset:(fun ~self:_ ~input ~model ->
              left_seen := (input, model) :: !left_seen;
              ( model + 100,
                Some
                  (Eta.Effect.sync (fun () ->
                       incr left_effects)) ))
            ~apply_action:(fun ~self:_ ~input:_ ~model:_ ~action ->
              (action, None))
        in
        let right =
          Crux.State_machine.create input ~default_model:10
            ~reset:(fun ~self:_ ~input ~model ->
              right_seen := (input, model) :: !right_seen;
              ( model + 1_000,
                Some
                  (Eta.Effect.sync (fun () ->
                       incr right_effects)) ))
            ~apply_action:(fun ~self:_ ~input:_ ~model:_ ~action ->
              (action, None))
        in
        let open Crux.Syntax in
        let+ authority = reset
        and+ (left, right) = Crux.both left right in
        (authority, left, right))
  in
  let root =
    Crux.Root.create
      ~post_commit_effect_observer:(Observer.attachment observer)
      ~ingress_capacity:4 ~request_capacity:1 description
  in
  let authority, (left_model, left_endpoint),
      (right_model, right_endpoint) =
    committed runtime root
  in
  Alcotest.(check (pair int int)) "initial models" (1, 10)
    (left_model, right_model);
  ignore (Observer.drain observer);
  send runtime left_endpoint 3;
  ignore (committed runtime root);
  send runtime right_endpoint 30;
  ignore (committed runtime root);
  ignore (Observer.drain observer);
  reset runtime authority;
  let _, (left_model, _), (right_model, _) =
    committed runtime root
  in
  Alcotest.(check (pair int int)) "one atomic reset output"
    (103, 1_030) (left_model, right_model);
  Alcotest.(check (list (pair int int))) "left pre-reset snapshot"
    [ (2, 3) ] (List.rev !left_seen);
  Alcotest.(check (list (pair int int))) "right pre-reset snapshot"
    [ (2, 30) ] (List.rev !right_seen);
  let effect_count =
    match Observer.poll observer with
    | Some (Observer.Staged { effects; _ }) ->
        List.length effects
    | Some _ | None -> Alcotest.fail "reset inventory missing"
  in
  Alcotest.(check int) "two reset effects staged" 2 effect_count;
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check (pair int int)) "both reset effects ran"
    (1, 1) (!left_effects, !right_effects)

let test_nested_reset_scope_boundary () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let description =
    Crux.Reset.scope (Crux.return ())
      ~f:(fun ~reset:outer_reset ~input ->
        let outer =
          Crux.State_machine.create input ~default_model:1
            ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
              (action, None))
        in
        let inner =
          Crux.Reset.scope input
            ~f:(fun ~reset:inner_reset ~input ->
              let machine =
                Crux.State_machine.create input ~default_model:10
                  ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
                    (action, None))
              in
              Crux.both inner_reset machine)
        in
        let open Crux.Syntax in
        let+ outer_reset = outer_reset
        and+ outer = outer
        and+ inner = inner in
        (outer_reset, outer, inner))
  in
  let root =
    Crux.Root.create ~ingress_capacity:4 ~request_capacity:1
      description
  in
  let outer_reset, (outer_model, outer_endpoint),
      (inner_reset, (inner_model, inner_endpoint)) =
    committed runtime root
  in
  Alcotest.(check (pair int int)) "nested initial" (1, 10)
    (outer_model, inner_model);
  send runtime outer_endpoint 2;
  ignore (committed runtime root);
  send runtime inner_endpoint 20;
  ignore (committed runtime root);
  reset runtime inner_reset;
  let _, (outer_model, _), (_, (inner_model, _)) =
    committed runtime root
  in
  Alcotest.(check (pair int int)) "inner reset stayed inside"
    (2, 10) (outer_model, inner_model);
  send runtime inner_endpoint 30;
  ignore (committed runtime root);
  reset runtime outer_reset;
  let _, (outer_model, _), (_, (inner_model, _)) =
    committed runtime root
  in
  Alcotest.(check (pair int int)) "outer reset reached nested scope"
    (1, 10) (outer_model, inner_model)

let test_stale_reset_is_rejected_after_disposal () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let description =
    Crux.bind selector ~f:(fun (active, selector_endpoint) ->
        if active then
          Crux.Reset.scope (Crux.return ())
            ~f:(fun ~reset ~input:_ ->
              Crux.map reset ~f:(fun reset ->
                  (selector_endpoint, Some reset)))
        else Crux.return (selector_endpoint, None))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      description
  in
  let selector_endpoint, authority =
    committed runtime root
  in
  let authority = Option.get authority in
  send runtime selector_endpoint false;
  ignore (committed runtime root);
  reset runtime authority;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Rejected Crux.Root.Stale_reset) -> ()
  | _ -> Alcotest.fail "disposed reset authority was not stale"

let test_reset_callback_rollback () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let diagnostics =
    {
      Crux.Diagnostic.model =
        (fun model ->
          {
            Crux.Diagnostic.summary = string_of_int model;
            fields = [];
          });
      action =
        (fun action ->
          {
            Crux.Diagnostic.summary = string_of_int action;
            fields = [];
          });
    }
  in
  let description =
    Crux.Reset.scope (Crux.return ())
      ~f:(fun ~reset ~input ->
        let machine =
          Crux.State_machine.create input ~default_model:1
            ~diagnostics
            ~reset:(fun ~self:_ ~input:() ~model:_ ->
              failwith "reset callback failed")
            ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
              (action, None))
        in
        Crux.both reset machine)
  in
  let root =
    Crux.Root.create
      ~post_commit_effect_observer:(Observer.attachment observer)
      ~ingress_capacity:2 ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let deliver () =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) ->
        let output = Crux.Driver.Delivery.output delivery in
        ignore
          (run_ok runtime
             (Crux.Driver.Delivery.delivered delivery));
        output
    | _ -> Alcotest.fail "expected reset test delivery"
  in
  let authority, (_, endpoint) = deliver () in
  ignore (Observer.drain observer);
  send runtime endpoint 7;
  ignore (deliver ());
  ignore (Observer.drain observer);
  reset runtime authority;
  match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Crash_detected failure) ->
      let record = failure.Crux.Failure.primary in
      Alcotest.(check bool) "reset trigger" true
        (record.trigger = Crux.Failure.Structural_reset);
      Alcotest.(check bool) "cell retained" true
        (Option.is_some record.cell);
      Alcotest.(check bool) "no endpoint" true
        (Option.is_none record.endpoint);
      Alcotest.(check bool) "no action snapshot" true
        (Option.is_none record.action_snapshot);
      Alcotest.(check (option string)) "model snapshot"
        (Some "7")
        (Option.map
           (fun snapshot -> snapshot.Crux.Diagnostic.summary)
           record.model_snapshot);
      Alcotest.(check (option int)) "prior committed frame retained"
        (Some 7)
        (Crux.Driver.latest_committed_output driver
        |> Option.map (fun (_, (model, _)) -> model));
      Observer.expect_empty observer
  | _ -> Alcotest.fail "reset callback failure did not fail root"

let test_reset_effect_discarded_with_owner () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let observer = Observer.create () in
  let ran = ref false in
  let description =
    Crux.Reset.scope (Crux.return ())
      ~f:(fun ~reset ~input ->
        let selector =
          Crux.State_machine.create input ~default_model:true
            ~reset:(fun ~self:_ ~input:() ~model:_ ->
              (false, None))
            ~apply_action:(fun ~self:_ ~input:()
                              ~model:_ ~action ->
              (action, None))
        in
        let child =
          Crux.bind selector ~f:(fun (active, _) ->
              if not active then Crux.return ()
              else
                Crux.State_machine.create input ~default_model:()
                  ~reset:(fun ~self:_ ~input:() ~model:() ->
                    ( (),
                      Some
                        (Eta.Effect.sync (fun () ->
                             ran := true)) ))
                  ~apply_action:(fun ~self:_ ~input:()
                                    ~model:() ~action:() ->
                    ((), None))
                |> Crux.map ~f:(fun _ -> ()))
        in
        Crux.both reset (Crux.both selector child))
  in
  let root =
    Crux.Root.create
      ~post_commit_effect_observer:(Observer.attachment observer)
      ~ingress_capacity:1 ~request_capacity:1 description
  in
  let authority, _ = committed runtime root in
  ignore (Observer.drain observer);
  reset runtime authority;
  let post_commit =
    match run_ok runtime (Crux.Root.advance root) with
    | Ok (Crux.Root.Committed committed) -> committed.post_commit
    | _ -> Alcotest.fail "owner-disposing reset did not commit"
  in
  let effect =
    match Observer.drain observer with
    | [ Observer.Staged { effects = [ effect ]; _ } ] -> effect
    | _ -> Alcotest.fail "disposed reset effect was not staged"
  in
  start runtime post_commit;
  Alcotest.(check bool) "disposed effect did not run" false !ran;
  (match Observer.drain observer with
  | [ Observer.Discarded_before_start { effect = discarded; _ } ] ->
      Alcotest.(check bool) "discarded effect identity" true
        (Observer.Effect_id.compare effect discarded = 0)
  | _ -> Alcotest.fail "disposed reset effect was not discarded")

let () =
  Alcotest.run "eta_crux reset"
    [
      ( "reset",
        [
          Alcotest.test_case "snapshot atomicity and effect inventory"
            `Quick test_reset_snapshot_atomicity_and_effect_inventory;
          Alcotest.test_case "nested scope boundary" `Quick
            test_nested_reset_scope_boundary;
          Alcotest.test_case "stale after disposal" `Quick
            test_stale_reset_is_rejected_after_disposal;
          Alcotest.test_case "callback rollback" `Quick
            test_reset_callback_rollback;
          Alcotest.test_case "effect discarded with owner" `Quick
            test_reset_effect_discarded_with_owner;
        ] );
    ]
