module Plan = Eta_signal_observer_plan

type node = {
  node_id : int;
  dependencies : node list;
}

type observer = {
  observer_id : int;
  observed : node;
}

let access =
  Plan.access
    ~node_id:(fun node -> node.node_id)
    ~dependencies:(fun node -> node.dependencies)
    ~observer_id:(fun observer -> observer.observer_id)
    ~observed:(fun observer -> observer.observed)

let observer id observed = { observer_id = id; observed }
let observer_ids plan = List.map (fun observer -> observer.observer_id) plan

let ceil_log2 value =
  let rec loop power result =
    if power >= value then result else loop (power * 2) (result + 1)
  in
  loop 1 0

let check_counters label ~candidates ~union_nodes ~union_edges ~groups counters =
  Alcotest.(check int) (label ^ " candidate visits") candidates
    counters.Plan.candidate_visits;
  Alcotest.(check int) (label ^ " union nodes") union_nodes
    counters.Plan.union_node_visits;
  Alcotest.(check int) (label ^ " union edges") union_edges
    counters.Plan.union_edge_visits;
  Alcotest.(check int) (label ^ " ready pushes") groups
    counters.Plan.ready_pushes;
  Alcotest.(check int) (label ^ " ready pops") groups counters.Plan.ready_pops;
  Alcotest.(check bool) (label ^ " comparison bound") true
    (counters.Plan.ready_comparisons
    <= 4 * groups * ceil_log2 (groups + 1));
  Alcotest.(check int) (label ^ " no pairwise searches") 0
    counters.Plan.pairwise_search_visits

let plan_with counters observers =
  Plan.plan counters access ~cycle:(fun () -> Alcotest.fail "unexpected cycle")
    observers

let test_topological_order_uses_final_dependency_closure () =
  let rec dependency = { node_id = 1; dependencies = [] }
  and hidden = { node_id = 2; dependencies = [ dependency ] }
  and consumer = { node_id = 3; dependencies = [ hidden ] } in
  let counters = Plan.create_counters () in
  Plan.reset_counters counters;
  let plan =
    plan_with counters
      [ observer 30 consumer; observer 10 dependency; observer 20 consumer ]
  in
  Alcotest.(check (list int)) "same group and dependency order"
    [ 10; 20; 30 ] (observer_ids plan);
  check_counters "closure" ~candidates:3 ~union_nodes:3 ~union_edges:2
    ~groups:2
    (Plan.counter_snapshot counters)

let test_ready_unrelated_group_uses_smallest_observer_identity () =
  let dependency = { node_id = 1; dependencies = [] } in
  let consumer = { node_id = 2; dependencies = [ dependency ] } in
  let unrelated = { node_id = 3; dependencies = [] } in
  let counters = Plan.create_counters () in
  Plan.reset_counters counters;
  let plan =
    plan_with counters
      [
        observer 100 dependency;
        observer 50 consumer;
        observer 1 unrelated;
      ]
  in
  Alcotest.(check (list int)) "ready unrelated group first" [ 1; 100; 50 ]
    (observer_ids plan);
  check_counters "unrelated" ~candidates:3 ~union_nodes:3 ~union_edges:1
    ~groups:3
    (Plan.counter_snapshot counters)

let test_repeated_edges_and_same_signal_group_are_deterministic () =
  let dependency = { node_id = 1; dependencies = [] } in
  let consumer =
    { node_id = 2; dependencies = [ dependency; dependency ] }
  in
  let counters = Plan.create_counters () in
  Plan.reset_counters counters;
  let plan =
    plan_with counters
      [
        observer 9 consumer;
        observer 7 dependency;
        observer 5 consumer;
        observer 3 dependency;
      ]
  in
  Alcotest.(check (list int)) "groups use observer identity" [ 3; 7; 5; 9 ]
    (observer_ids plan);
  check_counters "repeated edge" ~candidates:4 ~union_nodes:2 ~union_edges:2
    ~groups:2
    (Plan.counter_snapshot counters)

let test_cycle_is_rejected_without_pairwise_search () =
  let rec left = { node_id = 1; dependencies = [ right ] }
  and right = { node_id = 2; dependencies = [ left ] } in
  let counters = Plan.create_counters () in
  Plan.reset_counters counters;
  match
    Plan.plan counters access
      ~cycle:(fun () -> raise Exit)
      [ observer 1 left; observer 2 right ]
  with
  | exception Exit -> ()
  | plan ->
      Alcotest.failf "cycle accepted: [%s]"
        (String.concat "," (List.map string_of_int (observer_ids plan)))

let () =
  Alcotest.run "eta_signal_observer_plan"
    [
      ( "observer plan",
        [
          Alcotest.test_case "topological final dependency closure" `Quick
            test_topological_order_uses_final_dependency_closure;
          Alcotest.test_case "ready unrelated group observer identity" `Quick
            test_ready_unrelated_group_uses_smallest_observer_identity;
          Alcotest.test_case "repeated edges same signal group" `Quick
            test_repeated_edges_and_same_signal_group_are_deterministic;
          Alcotest.test_case "cycle rejected without pairwise search" `Quick
            test_cycle_is_rejected_without_pairwise_search;
        ] );
    ]
