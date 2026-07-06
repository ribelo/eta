module State = Eta_signal_graph_state

let record events event = events := !events @ [ event ]

let string_list = Alcotest.(list string)

let create () : (string, string, string, string, string, string) State.t =
  State.create ()

let commit_plan ?(preflight = fun () -> ())
    ?(commit_bind = fun _bind -> []) ?(prepare_signal = fun node -> node)
    ?(commit_transaction = fun () -> ())
    ?(commit_timer_refresh = fun _timer -> ())
    ?(commit_signal = fun _prepared -> ())
    ?(advance_snapshot = fun value -> value + 1) () =
  State.commit_plan ~preflight
    ~binds:(State.bind_commit_plan ~commit:commit_bind)
    ~signals:(State.signal_commit_plan ~prepare_signal ~commit_signal)
    ~timers:(State.timer_commit_plan ~commit:commit_timer_refresh)
    ~snapshot:
      (State.snapshot_commit_plan ~commit_transaction ~advance_snapshot)

let test_generation_pending_and_active_refresh () =
  let state = create () in
  State.enqueue_pending state "first";
  State.enqueue_pending state "second";
  State.advance_generation state ~advance:(fun value -> value + 1);
  ignore (State.begin_staging state ~timer_refresh:(Some "refresh"));
  Alcotest.(check int) "generation" 1 (State.generation state);
  Alcotest.(check string_list)
    "pending order" [ "first"; "second" ]
    (State.drain_pending state);
  Alcotest.(check (option string))
    "active refresh" (Some "refresh")
    (State.active_timer_refresh state);
  State.clear_active_timer_refresh state;
  Alcotest.(check (option string))
    "cleared refresh" None
    (State.active_timer_refresh state)

let noop_reset_context =
  State.reset_context ~rollback_bind:(fun _ -> [])
    ~rollback_transaction:(fun () -> ())
    ~rollback_timer_refresh_dirty:(fun _ -> ())
    ~clear_timer_refresh_timer:(fun _ -> ())

let test_reset_staging_owns_state_cleanup_order () =
  let state = create () in
  let events = ref [] in
  let staging = State.begin_staging state ~timer_refresh:(Some "refresh") in
  State.stage_bind state staging "bind";
  State.remember_pure_disposal_hooks state staging [ "pure-hook" ];
  State.stage_timer_refresh_timer state staging "timer";
  let hooks =
    State.reset_staging state staging
      (State.reset_context
         ~rollback_bind:(fun bind ->
           record events ("rollback_bind:" ^ bind);
           [ "bind-hook" ])
         ~rollback_transaction:(fun () ->
           record events "rollback_transaction")
         ~rollback_timer_refresh_dirty:(fun refresh ->
           record events ("rollback_dirty:" ^ refresh))
         ~clear_timer_refresh_timer:(fun timer ->
           record events ("clear_timer:" ^ timer)))
  in
  Alcotest.(check string_list)
    "events"
    [
      "rollback_bind:bind";
      "rollback_transaction";
      "rollback_dirty:refresh";
      "clear_timer:timer";
    ]
    !events;
  Alcotest.(check string_list)
    "hooks" [ "bind-hook"; "pure-hook" ] hooks;
  Alcotest.(check string_list) "binds cleared" [] (State.staged_binds state);
  Alcotest.(check string_list) "nodes cleared" [] (State.computed_nodes state)

let test_commit_staging_owns_state_cleanup_order () =
  let state = create () in
  let events = ref [] in
  let staging = State.begin_staging state ~timer_refresh:(Some "refresh") in
  State.stage_bind state staging "bind";
  State.remember_computed state staging ~generation:1 "node"
    ~project:(fun node -> node)
    ~remember:(fun ~generation:_ nodes node -> node :: nodes);
  State.remember_pure_disposal_hooks state staging [ "pure-hook" ];
  State.remember_timer_refresh_disposal_hooks state staging [ "timer-hook" ];
  State.stage_timer_refresh_timer state staging "timer";
  let hooks =
    State.commit_staging state staging
      (commit_plan
         ~preflight:(fun () -> record events "preflight")
         ~commit_bind:(fun bind ->
           record events ("commit_bind:" ^ bind);
           [ "bind-hook" ])
         ~prepare_signal:(fun node ->
           record events ("prepare:" ^ node);
           node)
         ~commit_transaction:(fun () -> record events "commit_transaction")
         ~commit_timer_refresh:(fun timer ->
           record events ("commit_timer:" ^ timer))
         ~commit_signal:(fun node -> record events ("commit_signal:" ^ node))
         ())
  in
  Alcotest.(check string_list)
    "events"
    [
      "preflight";
      "commit_bind:bind";
      "prepare:node";
      "commit_transaction";
      "commit_timer:timer";
      "commit_signal:node";
    ]
    !events;
  Alcotest.(check string_list)
    "hooks" [ "bind-hook"; "pure-hook"; "timer-hook" ] hooks;
  Alcotest.(check int)
    "snapshot count" 1
    (State.pure_snapshot_commit_count state);
  Alcotest.(check string_list) "binds cleared" [] (State.staged_binds state);
  Alcotest.(check string_list) "nodes cleared" [] (State.computed_nodes state)

let test_commit_staging_generated_matrix () =
  let values prefix count =
    List.init count (fun index -> prefix ^ string_of_int index)
  in
  let cases =
    List.concat_map
      (fun bind_count ->
        List.concat_map
          (fun node_count ->
            List.concat_map
              (fun timer_count ->
                [
                  (bind_count, node_count, timer_count, false);
                  (bind_count, node_count, timer_count, true);
                ])
              [ 0; 1; 2 ])
          [ 0; 1; 2 ])
      [ 0; 1; 2 ]
  in
  List.iter
    (fun (bind_count, node_count, timer_count, active_refresh) ->
      let label =
        Printf.sprintf "binds=%d nodes=%d timers=%d refresh=%b"
          bind_count node_count timer_count active_refresh
      in
      let state = create () in
      let events = ref [] in
      let staging =
        State.begin_staging state
          ~timer_refresh:(if active_refresh then Some "refresh" else None)
      in
      let binds = values "bind" bind_count in
      let nodes = values "node" node_count in
      let timers = values "timer" timer_count in
      List.iter (State.stage_bind state staging) binds;
      List.iter
        (fun node ->
          State.remember_computed state staging ~generation:1 node
            ~project:(fun value -> value)
            ~remember:(fun ~generation:_ remembered value ->
              value :: remembered))
        nodes;
      List.iter (State.stage_timer_refresh_timer state staging) timers;
      State.remember_pure_disposal_hooks state staging [ "pure-hook" ];
      State.remember_timer_refresh_disposal_hooks state staging
        [ "timer-hook" ];
      let staged_binds = List.rev binds in
      let staged_nodes = List.rev nodes in
      let staged_timers = List.rev timers in
      let hooks =
        State.commit_staging state staging
          (commit_plan
             ~preflight:(fun () -> record events "preflight")
             ~commit_bind:(fun bind ->
               record events ("commit_bind:" ^ bind);
               [ "bind-hook:" ^ bind ])
             ~prepare_signal:(fun node ->
               record events ("prepare:" ^ node);
               node)
             ~commit_transaction:(fun () ->
               record events "commit_transaction")
             ~commit_timer_refresh:(fun timer ->
               record events ("commit_timer:" ^ timer))
             ~commit_signal:(fun node ->
               record events ("commit_signal:" ^ node))
             ())
      in
      let expected_events =
        [ "preflight" ]
        @ List.map (fun bind -> "commit_bind:" ^ bind) staged_binds
        @ List.map (fun node -> "prepare:" ^ node) staged_nodes
        @ [ "commit_transaction" ]
        @ List.map (fun timer -> "commit_timer:" ^ timer) staged_timers
        @ List.map (fun node -> "commit_signal:" ^ node) staged_nodes
      in
      Alcotest.(check string_list) (label ^ " events") expected_events
        !events;
      let expected_hooks =
        List.map (fun bind -> "bind-hook:" ^ bind) staged_binds
        @
        if active_refresh then [ "pure-hook"; "timer-hook" ]
        else [ "timer-hook"; "pure-hook" ]
      in
      Alcotest.(check string_list) (label ^ " hooks") expected_hooks hooks;
      Alcotest.(check int)
        (label ^ " snapshot count") 1
        (State.pure_snapshot_commit_count state);
      Alcotest.(check string_list)
        (label ^ " binds cleared") [] (State.staged_binds state);
      Alcotest.(check string_list)
        (label ^ " nodes cleared") [] (State.computed_nodes state))
    cases

let test_staging_token_validation () =
  let state = create () in
  let staging = State.begin_staging state ~timer_refresh:None in
  Alcotest.check_raises "begin while active"
    (Invalid_argument "Eta_signal graph staging is already active")
    (fun () -> ignore (State.begin_staging state ~timer_refresh:None));
  ignore (State.reset_staging state staging noop_reset_context : string list);
  Alcotest.check_raises "reuse stale token"
    (Invalid_argument "Eta_signal graph staging is not active")
    (fun () ->
      ignore
        (State.reset_staging state staging noop_reset_context : string list))

let test_staging_mutations_require_active_token () =
  let first = create () in
  let second = create () in
  let first_staging = State.begin_staging first ~timer_refresh:None in
  let second_staging = State.begin_staging second ~timer_refresh:None in
  State.stage_bind first first_staging "bind";
  State.remember_computed first first_staging ~generation:1 "node"
    ~project:(fun node -> node)
    ~remember:(fun ~generation:_ nodes node -> node :: nodes);
  State.remember_pure_disposal_hooks first first_staging [ "hook" ];
  State.remember_timer_refresh_disposal_hooks first first_staging
    [ "timer-hook" ];
  State.stage_timer_refresh_timer first first_staging "timer";
  Alcotest.check_raises "wrong active token"
    (Invalid_argument "Eta_signal graph staging token is not active")
    (fun () -> State.stage_bind first second_staging "wrong");
  ignore
    (State.reset_staging first first_staging noop_reset_context
      : string list);
  Alcotest.check_raises "stale token"
    (Invalid_argument "Eta_signal graph staging is not active")
    (fun () -> State.stage_bind first first_staging "stale");
  ignore
    (State.reset_staging second second_staging noop_reset_context
      : string list)

let test_timer_refresh_token_advances () =
  let state = create () in
  Alcotest.(check int)
    "first token" 0
    (State.next_timer_refresh_token state ~advance:(fun value -> value + 1));
  Alcotest.(check int)
    "second token" 1
    (State.next_timer_refresh_token state ~advance:(fun value -> value + 1))

let () =
  Alcotest.run "eta_signal_graph_state"
    [
      ( "graph_state",
        [
          Alcotest.test_case "generation pending refresh" `Quick
            test_generation_pending_and_active_refresh;
          Alcotest.test_case "reset staging state" `Quick
            test_reset_staging_owns_state_cleanup_order;
          Alcotest.test_case "commit staging state" `Quick
            test_commit_staging_owns_state_cleanup_order;
          Alcotest.test_case "generated commit staging matrix" `Quick
            test_commit_staging_generated_matrix;
          Alcotest.test_case "staging token validation" `Quick
            test_staging_token_validation;
          Alcotest.test_case "staging mutations require token" `Quick
            test_staging_mutations_require_active_token;
          Alcotest.test_case "timer refresh token" `Quick
            test_timer_refresh_token_advances;
        ] );
    ]
