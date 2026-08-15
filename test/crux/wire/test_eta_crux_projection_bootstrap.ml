module Crux = Eta_crux
module Harness = Eta_crux_test.Projection_harness
module Recipient = Harness.Wire_recipient

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let int_codec =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
    ~decode:(fun bytes ->
      match int_of_string_opt (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid integer" })

let projection () =
  Harness.create ~name:"bootstrap.value" ~codec:int_codec
    ~value_equal:Int.equal ~cutoff:Crux.Cutoff.never

type fixture = {
  driver : Crux.Driver.t;
  admin : Crux.Serialized_session.admin;
  candidate : Crux.Serialized_session.candidate;
  peer : Crux.Serialized_session.peer;
  endpoint : int Crux.Endpoint.t option ref;
  projection : int Harness.t;
}

let fixture ?observer ?(value = 0) () =
  let projection = projection () in
  let endpoint = ref None in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:value
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let description =
    Crux.map machine ~f:(fun (model, machine_endpoint) ->
        endpoint := Some machine_endpoint;
        model)
  in
  let root =
    Harness.root ?post_commit_effect_observer:observer projection
      ~projection_capacity:1 ~ingress_capacity:4 ~request_capacity:1
      description
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:8_192
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized ~operations:[] ~session:candidate
  in
  {
    driver = Crux.Driver.create binding root;
    admin;
    candidate;
    peer;
    endpoint;
    projection;
  }

let decode bytes =
  match Eta_crux_json.Format.decode bytes with
  | Ok frame -> frame
  | Error _ -> Alcotest.fail "serialized bootstrap frame did not decode"

let rec poll_frame runtime peer attempts =
  match run_ok runtime (Crux.Serialized_session.poll_outgoing peer) with
  | Some bytes -> (decode bytes, bytes)
  | None when attempts = 0 ->
      Alcotest.fail "serialized bootstrap frame missing"
  | None ->
      Eio.Fiber.yield ();
      poll_frame runtime peer (attempts - 1)

let receive runtime peer frame =
  run_ok runtime
    (Crux.Serialized_session.receive peer
       (Eta_crux_json.Format.encode frame))

let initial runtime fixture =
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  let frame, _ = poll_frame runtime fixture.peer 20 in
  match frame with
  | Crux.Wire.Frame.Projection_deliver
      { seq; reason = `Advancement; content = Updates updates } ->
      (seq, updates)
  | _ -> Alcotest.fail "initial session did not receive advancement updates"

let accept_initial runtime fixture =
  let sequence, updates = initial runtime fixture in
  Alcotest.(check bool) "initial result accepted" true
    (receive runtime fixture.peer
       (Crux.Wire.Frame.Projection_result
          { seq = 0l; reply_to = sequence; result = `Accepted })
    = Ok ());
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  updates

let send runtime fixture value =
  run_ok runtime
    (Crux.Endpoint.send (Option.get !(fixture.endpoint)) value
    |> Eta.Effect.or_die (fun Crux.Endpoint.Ingress_closed ->
           Failure "bootstrap fixture endpoint closed"))

let accept_advancement runtime fixture ~incoming_seq =
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  let frame, _ = poll_frame runtime fixture.peer 20 in
  let sequence =
    match frame with
    | Crux.Wire.Frame.Projection_deliver
        { seq; reason = `Advancement; content = Updates _ } ->
        seq
    | _ -> Alcotest.fail "expected advancement delivery"
  in
  Alcotest.(check bool) "advancement result accepted" true
    (receive runtime fixture.peer
       (Crux.Wire.Frame.Projection_result
          {
            seq = incoming_seq;
            reply_to = sequence;
            result = `Accepted;
          })
    = Ok ());
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver))

type replacement = {
  pending :
    (Crux.Serialized_session.replace_outcome, Crux.never)
      Eta.Exit.t
      Eta_test.Async.promise;
  peer : Crux.Serialized_session.peer;
  sequence : int32;
  entries : Crux.Wire.Frame.projection_entry list;
}

let begin_replacement switch runtime fixture ?(max_frame_bytes = 8_192) () =
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes
      ~format:(module Eta_crux_json.Format)
  in
  let pending =
    Eta_test.Async.fork_run switch runtime
      (Crux.Serialized_session.replace fixture.admin candidate
      |> Eta.Effect.or_die (fun error ->
             Failure
               (Format.asprintf "replacement rejected: %s"
                  (match error with
                  | Crux.Serialized_session.Starting -> "starting"
                  | Replacement_pending -> "replacement-pending"
                  | Awaiting_delivery -> "awaiting-delivery"
                  | Terminating -> "terminating"
                  | Closed -> "closed"))))
  in
  let frame, _ = poll_frame runtime peer 100 in
  match frame with
  | Crux.Wire.Frame.Projection_deliver
      {
        seq;
        reason = `Session_replacement;
        content = Bootstrap entries;
      } ->
      { pending; peer; sequence = seq; entries }
  | _ -> Alcotest.fail "replacement first frame was not a bootstrap"

let complete_replacement runtime fixture replacement result =
  Alcotest.(check bool) "replacement result accepted" true
    (receive runtime replacement.peer
       (Crux.Wire.Frame.Projection_result
          {
            seq = 0l;
            reply_to = replacement.sequence;
            result;
          })
    = Ok ());
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  match Eta_test.Async.await replacement.pending with
  | Eta.Exit.Ok outcome -> outcome
  | Eta.Exit.Error cause ->
      Alcotest.failf "replacement waiter failed: %a"
        (Eta.Cause.pp (fun _ (value : Crux.never) ->
             match value with _ -> .))
        cause

let entry_value = function
  | [ (entry : Crux.Wire.Frame.projection_entry) ] ->
      int_of_string (Bytes.to_string entry.value)
  | _ -> Alcotest.fail "expected one bootstrap entry"

let entry_incarnation = function
  | [ (entry : Crux.Wire.Frame.projection_entry) ] ->
      entry.incarnation
  | _ -> Alcotest.fail "expected one bootstrap entry"

let test_projection_bootstrap_source () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  send runtime fixture 7;
  accept_advancement runtime fixture ~incoming_seq:1l;
  let replacement = begin_replacement switch runtime fixture () in
  Alcotest.(check int) "bootstrap uses latest committed value" 7
    (entry_value replacement.entries);
  Alcotest.(check bool) "replacement completed" true
    (complete_replacement runtime fixture replacement `Accepted
    = Crux.Serialized_session.Replaced)

let test_projection_bootstrap_incarnation_continuity () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  let updates = accept_initial runtime fixture in
  let initial_incarnation =
    match updates with
    | [ Crux.Wire.Frame.Attached entry ] -> entry.incarnation
    | _ -> Alcotest.fail "initial attachment missing"
  in
  let replacement = begin_replacement switch runtime fixture () in
  Alcotest.(check int64) "bootstrap incarnation retained"
    initial_incarnation (entry_incarnation replacement.entries);
  ignore (complete_replacement runtime fixture replacement `Accepted)

let test_projection_bootstrap_atomic_install () =
  let keyed =
    Harness.Keyed.create ~name:"bootstrap.atomic"
      ~key_compare:Int.compare ~key_codec:int_codec
      ~value_codec:int_codec ~value_equal:Int.equal
      ~cutoff:Crux.Cutoff.never
  in
  let recipient = Recipient.create keyed ~capacity:2 in
  let entry key incarnation value =
    {
      Crux.Wire.Frame.kind = "bootstrap.atomic";
      key = Bytes.of_string (string_of_int key);
      incarnation;
      value = Bytes.of_string (string_of_int value);
    }
  in
  let apply entries =
    Recipient.apply recipient
      (Crux.Wire.Frame.Projection_deliver
         {
           seq = 0l;
           reason = `Session_replacement;
           content = Bootstrap entries;
         })
  in
  Alcotest.(check bool) "initial bootstrap installed" true
    (apply [ entry 1 1L 10; entry 2 2L 20 ] = Ok ());
  Alcotest.(check bool) "invalid replacement rejected atomically" true
    (apply [ entry 2 2L 30; entry 2 3L 40 ]
    = Error Recipient.Duplicate_identity);
  Alcotest.(check (option int)) "prior key one retained" (Some 10)
    (Recipient.find_value recipient ~key:1);
  Alcotest.(check (option int)) "prior key two retained" (Some 20)
    (Recipient.find_value recipient ~key:2);
  Alcotest.(check bool) "valid bootstrap replaces complete state" true
    (apply [ entry 2 2L 30 ] = Ok ());
  Alcotest.(check (option int)) "absent identity left state" None
    (Recipient.find_value recipient ~key:1)

let test_projection_replacement_step_order () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  let replacement = begin_replacement switch runtime fixture () in
  Alcotest.(check bool) "old session closed before bootstrap observation" true
    (match
       run_ok runtime
         (Crux.Serialized_session.receive fixture.peer
            (Bytes.of_string "{}"))
     with
    | Error Crux.Serialized_session.Session_closed -> true
    | _ -> false);
  ignore (complete_replacement runtime fixture replacement `Accepted)

let test_projection_bootstrap_first_delivery () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  let replacement = begin_replacement switch runtime fixture () in
  Alcotest.(check int) "bootstrap is nonempty" 1
    (List.length replacement.entries);
  ignore (complete_replacement runtime fixture replacement `Accepted)

let replace_result runtime admin candidate =
  run_ok runtime
    (Eta.Effect.to_result
       (Crux.Serialized_session.replace admin candidate))

let candidate () =
  Crux.Serialized_session.candidate ~max_frame_bytes:8_192
    ~format:(module Eta_crux_json.Format)

let test_replace_error_starting () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fixture = fixture () in
  let next, _ = candidate () in
  Alcotest.(check bool) "starting replacement rejected" true
    (replace_result runtime fixture.admin next
    = Error Crux.Serialized_session.Starting)

let test_replace_error_awaiting_delivery () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fixture = fixture () in
  ignore (initial runtime fixture);
  let next, _ = candidate () in
  Alcotest.(check bool) "pending delivery replacement rejected" true
    (replace_result runtime fixture.admin next
    = Error Crux.Serialized_session.Awaiting_delivery)

let test_replace_error_replacement_pending () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  let replacement = begin_replacement switch runtime fixture () in
  let next, _ = candidate () in
  Alcotest.(check bool) "second replacement rejected" true
    (replace_result runtime fixture.admin next
    = Error Crux.Serialized_session.Replacement_pending);
  ignore (complete_replacement runtime fixture replacement `Accepted)

let test_replace_error_terminating () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  Crux.Driver.request_stop fixture.driver;
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  let next, _ = candidate () in
  Alcotest.(check bool) "terminating replacement rejected" true
    (replace_result runtime fixture.admin next
    = Error Crux.Serialized_session.Terminating)

let test_replace_error_closed () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  Crux.Driver.request_stop fixture.driver;
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  let next, _ = candidate () in
  Alcotest.(check bool) "closed replacement rejected" true
    (replace_result runtime fixture.admin next
    = Error Crux.Serialized_session.Closed)

let test_replace_claimed_candidate_preserves_owner () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let owner = fixture () in
  let replacement = fixture () in
  ignore (accept_initial runtime owner);
  ignore (accept_initial runtime replacement);
  (match
     Eta.Runtime.run runtime
       (Crux.Serialized_session.replace replacement.admin
          owner.candidate
       |> Eta.Effect.or_die (fun _ ->
              Failure "claimed candidate returned a typed error"))
   with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ ->
      Alcotest.fail "claimed replacement candidate was accepted");
  send runtime owner 1;
  ignore (run_ok runtime (Crux.Driver.poll owner.driver));
  let frame, _ = poll_frame runtime owner.peer 20 in
  let sequence =
    match frame with
    | Crux.Wire.Frame.Projection_deliver
        { seq; reason = `Advancement; content = Updates _ } ->
        seq
    | _ ->
        Alcotest.fail "claimed candidate owner lost its session"
  in
  Alcotest.(check bool) "owner delivery result accepted" true
    (receive runtime owner.peer
       (Crux.Wire.Frame.Projection_result
          { seq = 1l; reply_to = sequence; result = `Accepted })
    = Ok ());
  ignore (run_ok runtime (Crux.Driver.poll owner.driver));
  Crux.Driver.request_stop owner.driver;
  Crux.Driver.request_stop replacement.driver

let empty_fixture () =
  let root =
    Crux.Root.create ~catalog:(Crux.Projection.Catalog.create [])
      ~projection_capacity:1 ~ingress_capacity:2 ~request_capacity:1
      (Crux.return ())
  in
  let candidate, peer = candidate () in
  let binding, admin =
    Crux.Driver.Binding.serialized ~operations:[] ~session:candidate
  in
  (Crux.Driver.create binding root, admin, peer)

let test_projection_replace_empty_bootstrap () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let driver, admin, peer = empty_fixture () in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let initial, _ = poll_frame runtime peer 20 in
  let initial_sequence =
    match initial with
    | Crux.Wire.Frame.Projection_deliver
        { seq; content = Updates []; _ } ->
        seq
    | _ -> Alcotest.fail "empty initial delivery was not empty updates"
  in
  ignore
    (receive runtime peer
       (Crux.Wire.Frame.Projection_result
          { seq = 0l; reply_to = initial_sequence; result = `Accepted }));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let next, next_peer = candidate () in
  let pending =
    Eta_test.Async.fork_run switch runtime
      (Crux.Serialized_session.replace admin next
      |> Eta.Effect.or_die (fun _ -> Failure "empty replacement rejected"))
  in
  let bootstrap, _ = poll_frame runtime next_peer 100 in
  let sequence =
    match bootstrap with
    | Crux.Wire.Frame.Projection_deliver
        { seq; content = Bootstrap []; _ } ->
        seq
    | _ -> Alcotest.fail "empty replacement bootstrap was not empty"
  in
  ignore
    (receive runtime next_peer
       (Crux.Wire.Frame.Projection_result
          { seq = 0l; reply_to = sequence; result = `Accepted }));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  (match Eta_test.Async.await pending with
  | Eta.Exit.Ok Crux.Serialized_session.Replaced -> ()
  | _ -> Alcotest.fail "empty bootstrap replacement did not complete")

let test_projection_commit_no_session () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  ignore
    (run_ok runtime
       (Crux.Serialized_session.receive fixture.peer
          (Bytes.of_string "{}")));
  send runtime fixture 5;
  let rec await_closed attempts =
    match run_ok runtime (Crux.Driver.poll fixture.driver) with
    | Some (Crux.Driver.Closed (Crux.Driver.Crashed settlement)) ->
        settlement
    | _ when attempts = 0 ->
        Alcotest.fail "commit without session did not crash"
    | _ -> await_closed (attempts - 1)
  in
  let settlement = await_closed 30 in
  Alcotest.(check bool) "commit stayed published" true
    (match Crux.Driver.latest_committed_snapshot fixture.driver with
    | None -> false
    | Some snapshot ->
        Harness.snapshot_value fixture.projection snapshot = Some 5);
  Alcotest.(check bool) "no-session failure trigger" true
    (settlement.failure.primary.trigger
    = Crux.Failure.Projection_delivery)

let test_projection_replace_in_loss_window () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  ignore
    (run_ok runtime
       (Crux.Serialized_session.receive fixture.peer
          (Bytes.of_string "{}")));
  let replacement = begin_replacement switch runtime fixture () in
  Alcotest.(check int) "loss-window bootstrap value" 0
    (entry_value replacement.entries);
  ignore (complete_replacement runtime fixture replacement `Accepted)

let test_projection_bootstrap_no_post_commit () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let observer =
    Eta_crux_test.Post_commit_effect_observer.create ()
  in
  let fixture =
    fixture
      ~observer:
        (Eta_crux_test.Post_commit_effect_observer.attachment
           observer)
      ()
  in
  ignore (accept_initial runtime fixture);
  ignore
    (Eta_crux_test.Post_commit_effect_observer.drain observer);
  let replacement = begin_replacement switch runtime fixture () in
  ignore (complete_replacement runtime fixture replacement `Accepted);
  Eta_crux_test.Post_commit_effect_observer.expect_empty observer

let test_projection_bootstrap_failure_crashes () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  let replacement = begin_replacement switch runtime fixture () in
  match
    complete_replacement runtime fixture replacement
      (`Failed "adapter rejected bootstrap")
  with
  | Crux.Serialized_session.Crashed failure ->
      Alcotest.(check bool) "bootstrap rejection origin" true
        (failure.primary.origin = Crux.Failure.Adapter_delivery);
      Alcotest.(check bool) "bootstrap rejection trigger" true
        (failure.primary.trigger = Crux.Failure.Projection_delivery)
  | Replaced | Stopped ->
      Alcotest.fail "failed bootstrap did not crash"

let test_projection_bootstrap_session_loss () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  let replacement = begin_replacement switch runtime fixture () in
  ignore
    (run_ok runtime
       (Crux.Serialized_session.receive replacement.peer
          (Bytes.of_string "{}")));
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  (match Eta_test.Async.await replacement.pending with
  | Eta.Exit.Ok (Crux.Serialized_session.Crashed failure) ->
      Alcotest.(check bool) "bootstrap loss trigger" true
        (failure.primary.trigger = Crux.Failure.Projection_delivery)
  | _ -> Alcotest.fail "bootstrap session loss did not crash")

let test_projection_advancement_fence () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let fixture = fixture () in
  ignore (accept_initial runtime fixture);
  let replacement = begin_replacement switch runtime fixture () in
  send runtime fixture 9;
  Alcotest.(check bool) "replacement fences advancement" true
    (run_ok runtime (Crux.Driver.poll fixture.driver) = None);
  Alcotest.(check bool) "fenced commit stayed old" true
    (match Crux.Driver.latest_committed_snapshot fixture.driver with
    | None -> false
    | Some snapshot ->
        Harness.snapshot_value fixture.projection snapshot = Some 0);
  ignore (complete_replacement runtime fixture replacement `Accepted);
  ignore (run_ok runtime (Crux.Driver.poll fixture.driver));
  Alcotest.(check bool) "advancement ran after bootstrap" true
    (match Crux.Driver.latest_committed_snapshot fixture.driver with
    | None -> false
    | Some snapshot ->
        Harness.snapshot_value fixture.projection snapshot = Some 9)

let test_projection_bootstrap_frame_too_large () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let large_codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string value))
      ~decode:(fun bytes -> Ok (Bytes.to_string bytes))
  in
  let projection =
    Harness.create ~name:"bootstrap.too-large" ~codec:large_codec
      ~value_equal:String.equal ~cutoff:Crux.Cutoff.never
  in
  let root =
    Harness.root projection ~projection_capacity:1 ~ingress_capacity:1
      ~request_capacity:1 (Crux.return (String.make 2_048 'x'))
  in
  let old_candidate, old_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:8_192
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized ~operations:[] ~session:old_candidate
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let initial, _ = poll_frame runtime old_peer 20 in
  let initial_sequence =
    match initial with
    | Crux.Wire.Frame.Projection_deliver { seq; _ } -> seq
    | _ -> Alcotest.fail "large initial projection missing"
  in
  ignore
    (receive runtime old_peer
       (Crux.Wire.Frame.Projection_result
          { seq = 0l; reply_to = initial_sequence; result = `Accepted }));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let next, next_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:128
      ~format:(module Eta_crux_json.Format)
  in
  let outcome =
    run_ok runtime
      (Crux.Serialized_session.replace admin next
      |> Eta.Effect.or_die (fun _ ->
             Failure "oversize replacement rejected before delivery"))
  in
  (match outcome with
  | Crux.Serialized_session.Crashed failure ->
      Alcotest.(check bool) "oversize bootstrap trigger" true
        (failure.primary.trigger = Crux.Failure.Projection_delivery)
  | Replaced | Stopped ->
      Alcotest.fail "oversize bootstrap did not crash");
  Alcotest.(check bool) "oversize new session closed" true
    (match
       run_ok runtime
         (Crux.Serialized_session.receive next_peer
            (Bytes.of_string "{}"))
     with
    | Error Crux.Serialized_session.Session_closed -> true
    | _ -> false)

let test_projection_initial_attach_no_bootstrap () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let fixture = fixture () in
  let _sequence, updates = initial runtime fixture in
  match updates with
  | [ Crux.Wire.Frame.Attached _ ] -> ()
  | _ -> Alcotest.fail "initial attach used bootstrap or wrong updates"

let () =
  Alcotest.run "eta_crux projection bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case "source" `Quick
            test_projection_bootstrap_source;
          Alcotest.test_case "incarnation continuity" `Quick
            test_projection_bootstrap_incarnation_continuity;
          Alcotest.test_case "atomic install" `Quick
            test_projection_bootstrap_atomic_install;
          Alcotest.test_case "replacement order" `Quick
            test_projection_replacement_step_order;
          Alcotest.test_case "first delivery" `Quick
            test_projection_bootstrap_first_delivery;
          Alcotest.test_case "replace starting" `Quick
            test_replace_error_starting;
          Alcotest.test_case "replace pending" `Quick
            test_replace_error_replacement_pending;
          Alcotest.test_case "replace awaiting delivery" `Quick
            test_replace_error_awaiting_delivery;
          Alcotest.test_case "replace terminating" `Quick
            test_replace_error_terminating;
          Alcotest.test_case "replace closed" `Quick
            test_replace_error_closed;
          Alcotest.test_case "claimed candidate preserves owner" `Quick
            test_replace_claimed_candidate_preserves_owner;
          Alcotest.test_case "empty bootstrap" `Quick
            test_projection_replace_empty_bootstrap;
          Alcotest.test_case "commit without session" `Quick
            test_projection_commit_no_session;
          Alcotest.test_case "replace in loss window" `Quick
            test_projection_replace_in_loss_window;
          Alcotest.test_case "no post commit" `Quick
            test_projection_bootstrap_no_post_commit;
          Alcotest.test_case "bootstrap rejection" `Quick
            test_projection_bootstrap_failure_crashes;
          Alcotest.test_case "bootstrap session loss" `Quick
            test_projection_bootstrap_session_loss;
          Alcotest.test_case "advancement fence" `Quick
            test_projection_advancement_fence;
          Alcotest.test_case "bootstrap frame too large" `Quick
            test_projection_bootstrap_frame_too_large;
          Alcotest.test_case "initial attach" `Quick
            test_projection_initial_attach_no_bootstrap;
        ] );
    ]
