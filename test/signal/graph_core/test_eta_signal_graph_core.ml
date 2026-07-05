module Core = Eta_signal_graph_core
module Id = Eta_signal_id

let ok = function
  | Ok value -> value
  | Error (`Counter_overflow name) ->
      Alcotest.failf "unexpected counter overflow: %s" name
  | Error _ -> Alcotest.fail "unexpected graph error"

let expect_overflow label expected = function
  | Error (`Counter_overflow actual) ->
      Alcotest.(check string) label expected actual
  | Error _ -> Alcotest.failf "%s: unexpected graph error" label
  | Ok _ -> Alcotest.failf "%s: expected counter overflow" label

let signal_set ids =
  let table = Hashtbl.create 4 in
  List.iter (fun id -> Hashtbl.replace table (Id.signal id) ()) ids;
  table

let worker_context_active = ref false

let () =
  Eta.Runtime_contract.register_worker_context_probe (fun () ->
      !worker_context_active)

let test_allocates_ids_from_graph_core () =
  let core = Core.create () in
  Alcotest.(check int) "signal id" 0
    (Id.signal_int (ok (Core.next_signal_id core)));
  Alcotest.(check int) "var id" 1
    (Id.var_int (ok (Core.next_var_id core)));
  Alcotest.(check int) "observer id" 2
    (Id.observer_int (ok (Core.next_observer_id core)));
  Alcotest.(check int) "scope id" 1
    (Id.scope_int (ok (Core.next_scope_id core)))

let test_allocator_overflows_loudly () =
  let core = Core.create () in
  Core.set_next_node_id core max_int;
  expect_overflow "node id" "node id" (Core.next_signal_id core);
  Core.set_next_scope_id core max_int;
  expect_overflow "scope id" "scope id" (Core.next_scope_id core)

let test_counters_saturate_and_can_be_seeded () =
  let core = Core.create () in
  Core.bump_counter core Core.Recompute_count;
  Alcotest.(check int) "bumped" 1
    (Core.counter core Core.Recompute_count);
  Core.set_counter core Core.Recompute_count max_int;
  Core.bump_counter core Core.Recompute_count;
  Alcotest.(check int) "saturated" max_int
    (Core.counter core Core.Recompute_count)

let test_necessary_id_updates_count_transitions () =
  let core = Core.create () in
  Core.update_necessary_ids core (signal_set [ 1; 2 ]);
  Alcotest.(check int) "became necessary first" 2
    (Core.counter core Core.Nodes_became_necessary);
  Alcotest.(check int) "became unnecessary first" 0
    (Core.counter core Core.Nodes_became_unnecessary);
  Core.update_necessary_ids core (signal_set [ 2; 3; 4 ]);
  Alcotest.(check int) "became necessary second" 4
    (Core.counter core Core.Nodes_became_necessary);
  Alcotest.(check int) "became unnecessary second" 1
    (Core.counter core Core.Nodes_became_unnecessary)

let test_context_validation_is_owned_by_graph_core () =
  let core = Core.create () in
  Core.ensure_context core;
  Fun.protect
    ~finally:(fun () -> worker_context_active := false)
    (fun () ->
      worker_context_active := true;
      match Core.ensure_context core with
      | () -> Alcotest.fail "expected worker-context rejection"
      | exception Invalid_argument message ->
          Alcotest.(check string)
            "context error" Core.context_error_message message)

let () =
  Alcotest.run "eta_signal_graph_core"
    [
      ( "graph_core",
        [
          Alcotest.test_case "allocates ids" `Quick
            test_allocates_ids_from_graph_core;
          Alcotest.test_case "allocator overflows loudly" `Quick
            test_allocator_overflows_loudly;
          Alcotest.test_case "counters saturate" `Quick
            test_counters_saturate_and_can_be_seeded;
          Alcotest.test_case "necessary id transitions" `Quick
            test_necessary_id_updates_count_transitions;
          Alcotest.test_case "context validation" `Quick
            test_context_validation_is_owned_by_graph_core;
        ] );
    ]
