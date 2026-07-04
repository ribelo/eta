module State = Eta_signal_graph_state

let record events event = events := !events @ [ event ]

let string_list = Alcotest.(list string)

let create () : (string, string, string, string, string, string) State.t =
  State.create ()

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

let test_reset_staging_owns_state_cleanup_order () =
  let state = create () in
  let events = ref [] in
  let staging = State.begin_staging state ~timer_refresh:(Some "refresh") in
  State.stage_bind state "bind";
  State.remember_pure_disposal_hooks state [ "pure-hook" ];
  State.stage_timer_refresh_timer state "timer";
  let hooks =
    State.reset_staging state staging
      ~rollback_bind:(fun bind ->
        record events ("rollback_bind:" ^ bind);
        [ "bind-hook" ])
      ~rollback_transaction:(fun () -> record events "rollback_transaction")
      ~rollback_timer_refresh_dirty:(fun refresh ->
        record events ("rollback_dirty:" ^ refresh))
      ~clear_timer_refresh_timer:(fun timer ->
        record events ("clear_timer:" ^ timer))
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
  State.stage_bind state "bind";
  State.remember_computed state ~generation:1 "node"
    ~project:(fun node -> node)
    ~remember:(fun ~generation:_ nodes node -> node :: nodes);
  State.remember_pure_disposal_hooks state [ "pure-hook" ];
  State.remember_timer_refresh_disposal_hooks state [ "timer-hook" ];
  State.stage_timer_refresh_timer state "timer";
  let hooks =
    State.commit_staging state staging
      ~preflight:(fun () -> record events "preflight")
      ~commit_bind:(fun bind ->
        record events ("commit_bind:" ^ bind);
        [ "bind-hook" ])
      ~prepare_signal:(fun node -> record events ("prepare:" ^ node))
      ~commit_transaction:(fun () -> record events "commit_transaction")
      ~commit_timer_refresh:(fun timer ->
        record events ("commit_timer:" ^ timer))
      ~commit_signal:(fun node -> record events ("commit_signal:" ^ node))
      ~advance_snapshot:(fun value -> value + 1)
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

let test_staging_token_validation () =
  let state = create () in
  let staging = State.begin_staging state ~timer_refresh:None in
  Alcotest.check_raises "begin while active"
    (Invalid_argument "Eta_signal graph staging is already active")
    (fun () -> ignore (State.begin_staging state ~timer_refresh:None));
  ignore
    (State.reset_staging state staging ~rollback_bind:(fun _ -> [])
       ~rollback_transaction:(fun () -> ())
       ~rollback_timer_refresh_dirty:(fun _ -> ())
       ~clear_timer_refresh_timer:(fun _ -> ())
      : string list);
  Alcotest.check_raises "reuse stale token"
    (Invalid_argument "Eta_signal graph staging is not active")
    (fun () ->
      ignore
        (State.reset_staging state staging ~rollback_bind:(fun _ -> [])
           ~rollback_transaction:(fun () -> ())
           ~rollback_timer_refresh_dirty:(fun _ -> ())
           ~clear_timer_refresh_timer:(fun _ -> ())
          : string list))

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
          Alcotest.test_case "staging token validation" `Quick
            test_staging_token_validation;
          Alcotest.test_case "timer refresh token" `Quick
            test_timer_refresh_token_advances;
        ] );
    ]
