module Crux = Eta_crux

let codec encode decode =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (encode value)))
    ~decode:(fun bytes ->
      match decode (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid test value" })

let unit_codec = codec (fun () -> "") (fun value -> if value = "" then Some () else None)
let int_codec = codec string_of_int int_of_string_opt

let int_kind name =
  Crux.Projection.Kind.define ~name ~key_compare:Unit.compare
    ~key_codec:unit_codec ~value_codec:int_codec ~value_equal:Int.equal
    ~cutoff:(Crux.Cutoff.of_equal Int.equal)

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let start runtime post_commit =
  match
    run_ok runtime
      (Crux.Post_commit.start post_commit
      |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
        Failure "projection post-commit started twice"))
  with
  | Crux.Post_commit.Admitted -> ()
  | Stop_settled | Crash_settled _ ->
      Alcotest.fail "projection test root terminated"

let settle runtime post_commit =
  ignore
    (run_ok runtime
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
         Failure "projection post-commit started twice")))

type advancement = {
  commit : Crux.Projection.Commit.t;
  post_commit : Crux.Post_commit.t;
}

let committed runtime root =
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Committed { commit; post_commit }) ->
      { commit; post_commit }
  | Ok Idle -> Alcotest.fail "expected projection commit, got idle"
  | Ok (Rejected _) -> Alcotest.fail "expected projection commit, got rejection"
  | Ok (Stopped _) -> Alcotest.fail "expected projection commit, got stop"
  | Ok (Failed failure) ->
      Alcotest.failf "expected projection commit, got failure: %a"
        Crux.Failure.Packed_cause.pp failure.failure.primary.cause
  | Error _ -> Alcotest.fail "expected projection commit, got advance error"

let send runtime endpoint action =
  ignore
    (run_ok runtime
       (Crux.Endpoint.send endpoint action
       |> Eta.Effect.or_die (fun Crux.Endpoint.Ingress_closed ->
         Failure "projection test ingress closed")))

let test_projection_kind_generativity () =
  let left = int_kind "counter.left" in
  let right = int_kind "counter.right" in
  ignore
    (Crux.Projection.Catalog.create
       [ Crux.Projection.Kind.Pack left; Crux.Projection.Kind.Pack right ]);
  Alcotest.check_raises "same descriptor is rejected"
    (Invalid_argument
       "Eta_crux.Projection.Catalog.create: duplicate projection kind")
    (fun () ->
      ignore
        (Crux.Projection.Catalog.create
           [ Crux.Projection.Kind.Pack left; Crux.Projection.Kind.Pack left ]))

let test_projection_catalog_rejection () =
  let duplicate_left = int_kind "counter.duplicate" in
  let duplicate_right = int_kind "counter.duplicate" in
  Alcotest.check_raises "duplicate wire name"
    (Invalid_argument
       "Eta_crux.Projection.Catalog.create: duplicate projection kind name")
    (fun () ->
      ignore
        (Crux.Projection.Catalog.create
           [
             Crux.Projection.Kind.Pack duplicate_left;
             Crux.Projection.Kind.Pack duplicate_right;
           ]));
  List.iter
    (fun name ->
      let kind = int_kind name in
      Alcotest.check_raises ("invalid name " ^ name)
        (Invalid_argument
           "Eta_crux.Projection.Catalog.create: invalid projection kind name")
        (fun () ->
          ignore
            (Crux.Projection.Catalog.create
               [ Crux.Projection.Kind.Pack kind ])))
    [ ""; "Upper"; "bad/name"; "a" ^ String.make 128 'a' ];
  ignore (Crux.Projection.Catalog.create [])

let test_projection_catalog_shared_roots () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind = int_kind "shared-catalog" in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let make_root () =
    Crux.Root.create ~catalog ~projection_capacity:1
      ~ingress_capacity:1 ~request_capacity:1
      (Crux.Projection.publish kind ~key:() (Crux.return 1))
  in
  let left = make_root () in
  let right = make_root () in
  Eta_crux_test.Projection_harness.seed_incarnation_counter left
    Int64.minus_one;
  let left_commit = committed runtime left in
  let right_commit = committed runtime right in
  let incarnation commit =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot commit.commit)
    |> Option.get
    |> fun entry -> entry.incarnation
  in
  Alcotest.(check bool) "root counters are independent" false
    (Crux.Projection.Incarnation.equal
       (incarnation left_commit)
       (incarnation right_commit));
  start runtime left_commit.post_commit;
  start runtime right_commit.post_commit

let test_projection_capacity_positive () =
  let catalog = Crux.Projection.Catalog.create [] in
  List.iter
    (fun projection_capacity ->
      Alcotest.check_raises "nonpositive projection capacity"
        (Invalid_argument
           "Eta_crux.Root.create: projection_capacity must be positive")
        (fun () ->
          ignore
            (Crux.Root.create ~catalog ~projection_capacity
               ~ingress_capacity:1 ~request_capacity:1 (Crux.return ()))))
    [ 0; -1 ]

let test_projection_initial_commit () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind = int_kind "counter" in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let description =
    Crux.Projection.publish kind ~key:() (Crux.return 7)
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:1
      ~ingress_capacity:1 ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let event =
    Eta.Runtime.run runtime (Crux.Driver.poll driver)
    |> Eta_test.Expect.expect_ok
  in
  let delivery =
    match event with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | Some _ | None -> Alcotest.fail "expected projection delivery"
  in
  let batch =
    match Crux.Driver.Delivery.projection delivery with
    | Crux.Projection.Updates batch -> batch
    | Bootstrap _ -> Alcotest.fail "initial delivery was a bootstrap"
  in
  (match Crux.Projection.Batch.find_opt kind ~key:() batch with
  | [ Crux.Projection.Attached { value = 7; _ } ] -> ()
  | _ -> Alcotest.fail "initial batch did not attach the projection");
  let snapshot =
    match Crux.Driver.latest_committed_snapshot driver with
    | Some snapshot -> snapshot
    | None -> Alcotest.fail "committed snapshot was not published"
  in
  (match Crux.Projection.Snapshot.find_opt kind ~key:() snapshot with
  | Some { value = 7; _ } -> ()
  | _ -> Alcotest.fail "committed snapshot did not retain the projection");
  ignore
    (run_ok runtime
       (Crux.Driver.Delivery.delivered delivery));
  let empty_root =
    Crux.Root.create ~catalog:(Crux.Projection.Catalog.create [])
      ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.return "local-only")
  in
  let empty_driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) empty_root
  in
  let empty_delivery =
    match run_ok runtime (Crux.Driver.poll empty_driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "empty initial image had no delivery"
  in
  (match Crux.Driver.Delivery.projection empty_delivery with
  | Crux.Projection.Updates batch ->
      Alcotest.(check int) "empty initial batch" 0
        (Crux.Projection.Batch.fold batch ~init:0
           ~f:(fun count _ -> count + 1))
  | Bootstrap _ -> Alcotest.fail "empty initial delivery was a bootstrap");
  ignore
    (run_ok runtime
       (Crux.Driver.Delivery.delivered empty_delivery))

let test_projection_publish_local_value () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let hidden =
    Crux.Projection.Kind.define ~name:"hidden"
      ~key_compare:Unit.compare ~key_codec:unit_codec
      ~value_codec:int_codec ~value_equal:Int.equal
      ~cutoff:Crux.Cutoff.always
  in
  let visible = int_kind "visible" in
  let catalog =
    Crux.Projection.Catalog.create
      [
        Crux.Projection.Kind.Pack hidden;
        Crux.Projection.Kind.Pack visible;
      ]
  in
  let local =
    Crux.Projection.publish hidden ~key:() (Crux.return 7)
  in
  let description =
    Crux.Projection.publish visible ~key:()
      (Crux.map local ~f:(fun value -> value + 1))
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:2
      ~ingress_capacity:1 ~request_capacity:1 description
  in
  let commit = committed runtime root in
  let snapshot = Crux.Projection.Commit.snapshot commit.commit in
  (match Crux.Projection.Snapshot.find_opt visible ~key:() snapshot with
  | Some { value = 8; _ } -> ()
  | _ -> Alcotest.fail "publish cutoff changed the local candidate");
  start runtime commit.post_commit

let test_projection_cutoff_retention () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let endpoint = ref None in
  let kind =
    Crux.Projection.Kind.define ~name:"parity"
      ~key_compare:Unit.compare ~key_codec:unit_codec
      ~value_codec:int_codec ~value_equal:Int.equal
      ~cutoff:(Crux.Cutoff.of_equal (fun left right ->
        left mod 2 = right mod 2))
  in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let value =
    Crux.map machine ~f:(fun (model, machine_endpoint) ->
      endpoint := Some machine_endpoint;
      model)
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:1
      ~ingress_capacity:2 ~request_capacity:1
      (Crux.Projection.publish kind ~key:() value)
  in
  let initial = committed runtime root in
  let initial_entry =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot initial.commit)
    |> Option.get
  in
  start runtime initial.post_commit;
  send runtime (Option.get !endpoint) 2;
  let suppressed = committed runtime root in
  let suppressed_entry =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot suppressed.commit)
    |> Option.get
  in
  Alcotest.(check int) "suppressed value retained" 0 suppressed_entry.value;
  Alcotest.(check bool) "incarnation retained" true
    (Crux.Projection.Incarnation.equal initial_entry.incarnation
       suppressed_entry.incarnation);
  Alcotest.(check int) "suppressed batch empty" 0
    (Crux.Projection.Batch.fold
       (Crux.Projection.Commit.batch suppressed.commit)
       ~init:0 ~f:(fun count _ -> count + 1));
  start runtime suppressed.post_commit;
  send runtime (Option.get !endpoint) 3;
  let changed = committed runtime root in
  (match
     Crux.Projection.Batch.find_opt kind ~key:()
       (Crux.Projection.Commit.batch changed.commit)
   with
  | [ Crux.Projection.Changed { value = 3; incarnation; _ } ]
    when Crux.Projection.Incarnation.equal incarnation
           initial_entry.incarnation ->
      ()
  | _ -> Alcotest.fail "significant candidate was not Changed");
  start runtime changed.post_commit

let test_projection_identity_collision () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind = int_kind "collision" in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let description =
    Crux.both
      (Crux.Projection.publish kind ~key:() (Crux.return 1))
      (Crux.Projection.publish kind ~key:() (Crux.return 1))
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:2
      ~ingress_capacity:1 ~request_capacity:1 description
  in
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Failed { failure; post_commit }) ->
      Alcotest.(check bool) "collision cause is typed" true
        (Crux.Failure.Packed_cause.projection_preflight
           failure.primary.cause
        = Some Crux.Projection.Identity_collision);
      Alcotest.(check bool) "collision trigger" true
        (failure.primary.trigger = Crux.Failure.Projection_preflight);
      settle runtime post_commit
  | _ -> Alcotest.fail "projection identity collision committed"

let test_projection_replacement () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let endpoint = ref None in
  let kind = int_kind "replacement" in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let selected =
    Crux.map selector ~f:(fun (model, machine_endpoint) ->
      endpoint := Some machine_endpoint;
      model)
  in
  let description =
    Crux.bind selected ~f:(fun value ->
      Crux.Projection.publish kind ~key:() (Crux.return value))
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:2
      ~ingress_capacity:1 ~request_capacity:1 description
  in
  let initial = committed runtime root in
  let old_entry =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot initial.commit)
    |> Option.get
  in
  start runtime initial.post_commit;
  send runtime (Option.get !endpoint) 1;
  let replacement = committed runtime root in
  (match
     Crux.Projection.Batch.find_opt kind ~key:()
       (Crux.Projection.Commit.batch replacement.commit)
   with
  | [
   Crux.Projection.Removed { incarnation = removed; _ };
   Attached { incarnation = attached; value = 1; _ };
  ] ->
      Alcotest.(check bool) "removed incarnation matches old" true
        (Crux.Projection.Incarnation.equal removed old_entry.incarnation);
      Alcotest.(check bool) "replacement incarnation is fresh" false
        (Crux.Projection.Incarnation.equal removed attached)
  | _ -> Alcotest.fail "replacement was not adjacent Removed/Attached");
  start runtime replacement.post_commit

let test_projection_remove_last_identity () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let endpoint = ref None in
  let kind = int_kind "remove-last" in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let selected =
    Crux.map selector ~f:(fun (active, machine_endpoint) ->
        endpoint := Some machine_endpoint;
        active)
  in
  let description =
    Crux.bind selected ~f:(fun active ->
        if active then
          Crux.Projection.publish kind ~key:() (Crux.return 1)
          |> Crux.map ~f:ignore
        else Crux.return ())
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:1
      ~ingress_capacity:1 ~request_capacity:1 description
  in
  let initial = committed runtime root in
  let initial_entry =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot initial.commit)
    |> Option.get
  in
  start runtime initial.post_commit;
  send runtime (Option.get !endpoint) false;
  let removed = committed runtime root in
  (match
     Crux.Projection.Batch.find_opt kind ~key:()
       (Crux.Projection.Commit.batch removed.commit)
   with
  | [ Crux.Projection.Removed { incarnation; _ } ] ->
      Alcotest.(check bool) "removed incarnation matches old" true
        (Crux.Projection.Incarnation.equal incarnation
           initial_entry.incarnation)
  | _ -> Alcotest.fail "removing the final identity emitted no removal");
  Alcotest.(check bool) "target snapshot is empty" true
    (Crux.Projection.Snapshot.find_opt kind ~key:()
       (Crux.Projection.Commit.snapshot removed.commit)
    = None);
  start runtime removed.post_commit;
  send runtime (Option.get !endpoint) false;
  let unchanged_empty = committed runtime root in
  start runtime unchanged_empty.post_commit;
  send runtime (Option.get !endpoint) true;
  let reattached = committed runtime root in
  let reattached_entry =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot reattached.commit)
    |> Option.get
  in
  Alcotest.(check bool) "reattachment has a fresh incarnation" false
    (Crux.Projection.Incarnation.equal initial_entry.incarnation
       reattached_entry.incarnation);
  start runtime reattached.post_commit

let test_projection_capacity_one_replacement () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let endpoint = ref None in
  let kind = int_kind "replacement-capacity" in
  let catalog =
    Crux.Projection.Catalog.create [ Crux.Projection.Kind.Pack kind ]
  in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let selected =
    Crux.map selector ~f:(fun (model, machine_endpoint) ->
      endpoint := Some machine_endpoint;
      model)
  in
  let root =
    Crux.Root.create ~catalog ~projection_capacity:1
      ~ingress_capacity:1 ~request_capacity:1
      (Crux.bind selected ~f:(fun value ->
         Crux.Projection.publish kind ~key:() (Crux.return value)))
  in
  let initial = committed runtime root in
  start runtime initial.post_commit;
  send runtime (Option.get !endpoint) 1;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Failed { failure; post_commit }) ->
      Alcotest.(check bool) "replacement counts two updates" true
        (Crux.Failure.Packed_cause.projection_preflight
           failure.primary.cause
        = Some Crux.Projection.Projection_capacity_exceeded);
      settle runtime post_commit
  | _ -> Alcotest.fail "capacity-one replacement committed"

let test_projection_unknown_kind () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind = int_kind "not-cataloged" in
  let root =
    Crux.Root.create ~catalog:(Crux.Projection.Catalog.create [])
      ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Projection.publish kind ~key:() (Crux.return 1))
  in
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Failed { failure; post_commit }) ->
      Alcotest.(check bool) "unknown kind cause is typed" true
        (Crux.Failure.Packed_cause.projection_preflight
           failure.primary.cause
        = Some Crux.Projection.Unknown_kind);
      settle runtime post_commit
  | _ -> Alcotest.fail "unknown projection kind committed"

let test_projection_incarnation_exhausted () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind = int_kind "incarnation-exhausted" in
  let root =
    Crux.Root.create
      ~catalog:
        (Crux.Projection.Catalog.create
           [ Crux.Projection.Kind.Pack kind ])
      ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Projection.publish kind ~key:() (Crux.return 1))
  in
  Eta_crux_test.Projection_harness.seed_incarnation_counter root 0L;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Failed { failure; post_commit }) ->
      Alcotest.(check bool) "exhaustion cause is typed" true
        (Crux.Failure.Packed_cause.projection_preflight
           failure.primary.cause
        = Some Crux.Projection.Incarnation_exhausted);
      settle runtime post_commit
  | _ -> Alcotest.fail "exhausted incarnation counter committed"

let test_projection_incarnation_opaque () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind = int_kind "incarnation-opaque" in
  let commit =
    committed runtime
      (Crux.Root.create
         ~catalog:
           (Crux.Projection.Catalog.create
              [ Crux.Projection.Kind.Pack kind ])
         ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
         (Crux.Projection.publish kind ~key:() (Crux.return 1)))
  in
  let incarnation =
    Crux.Projection.Snapshot.find_opt kind ~key:()
      (Crux.Projection.Commit.snapshot commit.commit)
    |> Option.get
    |> fun entry -> entry.incarnation
  in
  Alcotest.(check bool) "opaque incarnation compares equal to itself" true
    (Crux.Projection.Incarnation.equal incarnation incarnation);
  Alcotest.(check int) "opaque incarnation ordering" 0
    (Crux.Projection.Incarnation.compare incarnation incarnation);
  start runtime commit.post_commit

let test_projection_typed_lookup_fold () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let first =
    Crux.Projection.Kind.define ~name:"lookup.first"
      ~key_compare:Int.compare ~key_codec:int_codec
      ~value_codec:int_codec ~value_equal:Int.equal
      ~cutoff:Crux.Cutoff.never
  in
  let second =
    Crux.Projection.Kind.define ~name:"lookup.second"
      ~key_compare:String.compare
      ~key_codec:(codec Fun.id Option.some)
      ~value_codec:int_codec ~value_equal:Int.equal
      ~cutoff:Crux.Cutoff.never
  in
  let catalog =
    Crux.Projection.Catalog.create
      [
        Crux.Projection.Kind.Pack first;
        Crux.Projection.Kind.Pack second;
      ]
  in
  let description =
    Crux.both
      (Crux.Projection.publish second ~key:"b" (Crux.return 20))
      (Crux.Projection.publish first ~key:1 (Crux.return 10))
  in
  let commit =
    committed runtime
      (Crux.Root.create ~catalog ~projection_capacity:2
         ~ingress_capacity:1 ~request_capacity:1 description)
  in
  let snapshot = Crux.Projection.Commit.snapshot commit.commit in
  let batch = Crux.Projection.Commit.batch commit.commit in
  Alcotest.(check (option int)) "typed snapshot lookup" (Some 10)
    (match Crux.Projection.Snapshot.find_opt first ~key:1 snapshot with
    | None -> None
    | Some entry -> Some entry.value);
  Alcotest.(check int) "missing typed lookup" 0
    (List.length
       (Crux.Projection.Batch.find_opt first ~key:2 batch));
  Alcotest.(check int) "snapshot fold cardinality" 2
    (Crux.Projection.Snapshot.fold snapshot ~init:0
       ~f:(fun count _ -> count + 1));
  Alcotest.(check int) "batch fold cardinality" 2
    (Crux.Projection.Batch.fold batch ~init:0
       ~f:(fun count _ -> count + 1));
  (match Crux.Projection.Batch.find_opt second ~key:"b" batch with
  | [ Crux.Projection.Attached { value = 20; _ } ] -> ()
  | _ -> Alcotest.fail "typed batch lookup lost its value");
  start runtime commit.post_commit

let initial_driver_snapshot runtime name description =
  let kind = int_kind name in
  let root =
    Crux.Root.create
      ~catalog:
        (Crux.Projection.Catalog.create
           [ Crux.Projection.Kind.Pack kind ])
      ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      (Crux.Projection.publish kind ~key:() description)
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let delivery =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "expected initial projection delivery"
  in
  let snapshot =
    Crux.Driver.latest_committed_snapshot driver |> Option.get
  in
  (kind, root, driver, delivery, snapshot)

let same_snapshot_entry kind expected actual =
  match
    Crux.Projection.Snapshot.find_opt kind ~key:() expected,
    Crux.Projection.Snapshot.find_opt kind ~key:() actual
  with
  | Some left, Some right ->
      left.value = right.value
      && Crux.Projection.Incarnation.equal left.incarnation
           right.incarnation
  | None, None -> true
  | Some _, None | None, Some _ -> false

let test_latest_committed_snapshot_retained_after_failed_delivery () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind, _root, driver, delivery, committed =
    initial_driver_snapshot runtime "retained.failed-delivery"
      (Crux.return 1)
  in
  let cause =
    Crux.Failure.Packed_cause.make ~pp_error:Format.pp_print_string
      (Eta.Cause.fail "injected delivery failure")
  in
  ignore (run_ok runtime (Crux.Driver.Delivery.failed delivery cause));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let retained =
    Crux.Driver.latest_committed_snapshot driver |> Option.get
  in
  Alcotest.(check bool) "failed delivery retained commit" true
    (same_snapshot_entry kind committed retained)

let test_latest_committed_snapshot_retained_after_stop () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let kind, _root, driver, delivery, committed =
    initial_driver_snapshot runtime "retained.stop" (Crux.return 1)
  in
  ignore (run_ok runtime (Crux.Driver.Delivery.delivered delivery));
  Crux.Driver.request_stop driver;
  (match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "driver did not stop");
  let retained =
    Crux.Driver.latest_committed_snapshot driver |> Option.get
  in
  Alcotest.(check bool) "stop retained commit" true
    (same_snapshot_entry kind committed retained)

let test_latest_committed_snapshot_retained_after_crash () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let endpoint = ref None in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        if action then raise (Failure "retained-crash");
        (0, None))
  in
  let description =
    Crux.map machine ~f:(fun (model, machine_endpoint) ->
        endpoint := Some machine_endpoint;
        model)
  in
  let kind, _root, driver, delivery, committed =
    initial_driver_snapshot runtime "retained.crash" description
  in
  ignore (run_ok runtime (Crux.Driver.Delivery.delivered delivery));
  send runtime (Option.get !endpoint) true;
  (match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Crash_detected _) -> ()
  | _ -> Alcotest.fail "driver did not report crash");
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let retained =
    Crux.Driver.latest_committed_snapshot driver |> Option.get
  in
  Alcotest.(check bool) "crash retained prior commit" true
    (same_snapshot_entry kind committed retained)

let () =
  Alcotest.run "eta_crux projection"
    [
      ( "projection",
        [
          Alcotest.test_case "kind generativity" `Quick
            test_projection_kind_generativity;
          Alcotest.test_case "catalog rejection" `Quick
            test_projection_catalog_rejection;
          Alcotest.test_case "catalog shared roots" `Quick
            test_projection_catalog_shared_roots;
          Alcotest.test_case "capacity positive" `Quick
            test_projection_capacity_positive;
          Alcotest.test_case "initial commit" `Quick
            test_projection_initial_commit;
          Alcotest.test_case "publish local value" `Quick
            test_projection_publish_local_value;
          Alcotest.test_case "cutoff retention" `Quick
            test_projection_cutoff_retention;
          Alcotest.test_case "identity collision" `Quick
            test_projection_identity_collision;
          Alcotest.test_case "replacement" `Quick
            test_projection_replacement;
          Alcotest.test_case "remove last identity" `Quick
            test_projection_remove_last_identity;
          Alcotest.test_case "replacement capacity" `Quick
            test_projection_capacity_one_replacement;
          Alcotest.test_case "unknown kind" `Quick
            test_projection_unknown_kind;
          Alcotest.test_case "incarnation exhausted" `Quick
            test_projection_incarnation_exhausted;
          Alcotest.test_case "incarnation opaque" `Quick
            test_projection_incarnation_opaque;
          Alcotest.test_case "typed lookup and fold" `Quick
            test_projection_typed_lookup_fold;
          Alcotest.test_case "commit retained after delivery failure" `Quick
            test_latest_committed_snapshot_retained_after_failed_delivery;
          Alcotest.test_case "commit retained after stop" `Quick
            test_latest_committed_snapshot_retained_after_stop;
          Alcotest.test_case "commit retained after crash" `Quick
            test_latest_committed_snapshot_retained_after_crash;
        ] );
    ]
