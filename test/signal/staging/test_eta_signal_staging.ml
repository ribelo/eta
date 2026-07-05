module Staging = Eta_signal_staging

let record events event = events := !events @ [ event ]

let test_reset_runs_callbacks_in_staging_order () =
  let events = ref [] in
  let hooks =
    Staging.reset
      (Staging.reset_ops
         ~rollback_binds:(fun _context ->
           record events "rollback_binds";
           [ "bind" ])
         ~pure_disposal_hooks:(fun _context ->
           record events "pure_disposal_hooks";
           [ "pure" ])
         ~rollback_transaction:(fun _context ->
           record events "rollback_transaction")
         ~clear_staging:(fun _context -> record events "clear_staging"))
  in
  Alcotest.(check (list string))
    "callback order"
    [
      "rollback_binds";
      "pure_disposal_hooks";
      "rollback_transaction";
      "clear_staging";
    ]
    !events;
  Alcotest.(check (list string)) "hooks" [ "bind"; "pure" ] hooks

let test_commit_runs_callbacks_in_staging_order () =
  let events = ref [] in
  let hooks =
    Staging.commit
      (Staging.commit_ops
         ~preflight:(fun _context -> record events "preflight")
         ~commit_binds:(fun _context ->
           record events "commit_binds";
           [ "bind-hook" ])
         ~remember_pure_disposal_hooks:(fun _context hooks ->
           record events
             ("remember_pure_disposal_hooks:" ^ String.concat "," hooks))
         ~prepare_signals:(fun _context -> record events "prepare_signals")
         ~commit_transaction:(fun _context ->
           record events "commit_transaction")
         ~commit_timer_refresh:(fun _context ->
           record events "commit_timer_refresh")
         ~commit_signals:(fun _context -> record events "commit_signals")
         ~disposal_hooks:(fun _context ->
           record events "disposal_hooks";
           [ "pure"; "timer" ])
         ~clear_staging:(fun _context -> record events "clear_staging")
         ~commit_snapshot:(fun _context -> record events "commit_snapshot"))
  in
  Alcotest.(check (list string))
    "callback order"
    [
      "preflight";
      "commit_binds";
      "remember_pure_disposal_hooks:bind-hook";
      "prepare_signals";
      "commit_transaction";
      "commit_timer_refresh";
      "commit_signals";
      "disposal_hooks";
      "clear_staging";
      "commit_snapshot";
    ]
    !events;
  Alcotest.(check (list string)) "hooks" [ "pure"; "timer" ] hooks

let () =
  Alcotest.run "eta_signal_staging"
    [
      ( "staging",
        [
          Alcotest.test_case "reset callback order" `Quick
            test_reset_runs_callbacks_in_staging_order;
          Alcotest.test_case "commit callback order" `Quick
            test_commit_runs_callbacks_in_staging_order;
        ] );
    ]
