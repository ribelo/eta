module Debug = Eta_signal_debug

let pp_counter_error formatter = function
  | `Counter_overflow name ->
      Format.fprintf formatter "Counter_overflow %S" name

let counter_error =
  Alcotest.testable pp_counter_error (fun left right -> left = right)

let test_stats_counter () =
  Alcotest.(check (result int counter_error)) "normal value" (Ok 12)
    (Debug.stats_counter ~name:"counter" 12);
  Alcotest.(check (result int counter_error)) "saturated value"
    (Error (`Counter_overflow "counter"))
    (Debug.stats_counter ~name:"counter" max_int)

let test_bool_field () =
  Alcotest.(check string) "true field" "valid=true"
    (Debug.bool_field "valid" true);
  Alcotest.(check string) "false field" "dirty=false"
    (Debug.bool_field "dirty" false)

let test_timer_fields () =
  let running =
    {
      Debug.timer_active = true;
      timer_running_generation = Some 7;
      timer_has_cancel = true;
      timer_finished = false;
      timer_generation = 7;
    }
  in
  Alcotest.(check (list string))
    "running fields"
    [
      "timer_state=running";
      "timer_active=true";
      "timer_running=7";
      "timer_cancel=true";
      "timer_finished=false";
      "timer_generation=7";
    ]
    (Debug.timer_fields ~state_label:"running" running);
  let finished =
    {
      Debug.timer_active = false;
      timer_running_generation = None;
      timer_has_cancel = false;
      timer_finished = true;
      timer_generation = 8;
    }
  in
  Alcotest.(check (list string))
    "finished fields"
    [
      "timer_active=false";
      "timer_running=none";
      "timer_cancel=false";
      "timer_finished=true";
      "timer_generation=8";
    ]
    (Debug.timer_fields finished)

let test_signal_state_fields () =
  let source =
    {
      Debug.signal_valid = true;
      signal_initialized = true;
      signal_dirty = false;
      signal_computing = false;
      signal_dependency_count = 0;
      signal_dependent_count = 2;
      signal_var =
        Some
          {
            Debug.signal_var_id_label = "v1";
            signal_var_queued = true;
            signal_var_updating = false;
          };
    }
  in
  Alcotest.(check (list string))
    "source state fields"
    [
      "valid=true";
      "initialized=true";
      "dirty=false";
      "computing=false";
      "dependencies=0";
      "dependents=2";
      "var_id=v1";
      "queued=true";
      "updating=false";
    ]
    (Debug.signal_state_fields source)

let test_signal_scope_fields () =
  Alcotest.(check (list string))
    "root scope"
    [ "scope=root"; "scope_id=root"; "scope_owner=root"; "scope_parent=root" ]
    (Debug.signal_scope_fields Debug.Signal_root_scope);
  let child =
    Debug.Signal_child_scope
      {
        signal_scope_id_label = "sc2";
        signal_scope_valid = false;
        signal_scope_owner_label = "s1";
        signal_scope_parent_label = "sc1";
      }
  in
  Alcotest.(check (list string))
    "child scope"
    [
      "scope=sc2:invalid";
      "scope_id=sc2";
      "scope_owner=s1";
      "scope_parent=sc1";
    ]
    (Debug.signal_scope_fields child)

let test_signal_label () =
  let signal =
    {
      Debug.signal_kind_label = "var";
      signal_id_label = "s1";
      signal_tombstone = false;
      signal_state = None;
      signal_scope = None;
      signal_timer_fields = [];
    }
  in
  Alcotest.(check string) "minimal signal label" "kind=var signal_id=s1"
    (Debug.signal_label signal);
  let tombstone =
    {
      Debug.signal_kind_label = "timer";
      signal_id_label = "dead_s3";
      signal_tombstone = true;
      signal_state =
        Some
          {
            Debug.signal_valid = false;
            signal_initialized = true;
            signal_dirty = false;
            signal_computing = false;
            signal_dependency_count = 1;
            signal_dependent_count = 0;
            signal_var = None;
          };
      signal_scope =
        Some
          (Debug.Signal_child_scope
             {
               signal_scope_id_label = "sc1";
               signal_scope_valid = true;
               signal_scope_owner_label = "s1";
               signal_scope_parent_label = "root";
             });
      signal_timer_fields = [ "timer_active=false"; "timer_generation=4" ];
    }
  in
  Alcotest.(check string)
    "full tombstone label"
    "kind=timer signal_id=dead_s3 tombstone=true valid=false \
     initialized=true dirty=false computing=false dependencies=1 dependents=0 \
     scope=sc1:valid scope_id=sc1 scope_owner=s1 scope_parent=root \
     timer_active=false timer_generation=4"
    (Debug.signal_label tombstone)

let test_observer_label () =
  let active =
    {
      Debug.observer_id_label = "o1";
      observer_state_label = "active";
      observer_value_state_label = "current";
      observer_delivery_state_label = "delivered";
      observer_missing_observed_signal_id_label = None;
    }
  in
  Alcotest.(check string)
    "active observer label"
    "observer:o1 observer_id=o1 state=active value_state=current \
     delivery_state=delivered"
    (Debug.observer_label active);
  let invalid =
    {
      Debug.observer_id_label = "o2";
      observer_state_label = "invalid_scope";
      observer_value_state_label = "failed_without_current";
      observer_delivery_state_label = "none";
      observer_missing_observed_signal_id_label = Some "s3";
    }
  in
  Alcotest.(check string)
    "invalid observer label"
    "observer:o2 observer_id=o2 state=invalid_scope \
     value_state=failed_without_current delivery_state=none \
     missing_observed_signal_id=s3"
    (Debug.observer_label invalid)

let test_render_dot () =
  let dot =
    Debug.render_dot
      ~nodes:
        [
          {
            Debug.dot_node_id = "s1";
            dot_node_label = "kind=map signal_id=s1";
            dot_node_dependency_ids = [ "s0"; "s0"; "dead_s2" ];
          };
        ]
      ~observers:
        [
          {
            Debug.dot_observer_id = "o1";
            dot_observer_label = "observer:o1";
            dot_observed_signal_id = Some "s1";
          };
          {
            Debug.dot_observer_id = "o2";
            dot_observer_label = "observer:o2 missing_observed_signal_id=s3";
            dot_observed_signal_id = None;
          };
        ]
  in
  Alcotest.(check string)
    "dot"
    "digraph eta_signal {\n\
    \  s1 [label=\"kind=map signal_id=s1\"];\n\
    \  s0 -> s1;\n\
    \  dead_s2 -> s1;\n\
    \  o1 [shape=box,label=\"observer:o1\"];\n\
    \  s1 -> o1 [style=dashed,label=\"observes\"];\n\
    \  o2 [shape=box,label=\"observer:o2 missing_observed_signal_id=s3\"];\n\
     }\n"
    dot

let () =
  Alcotest.run "eta_signal_debug"
    [
      ( "debug",
        [
          Alcotest.test_case "stats counter" `Quick test_stats_counter;
          Alcotest.test_case "bool field" `Quick test_bool_field;
          Alcotest.test_case "timer fields" `Quick test_timer_fields;
          Alcotest.test_case "signal state fields" `Quick
            test_signal_state_fields;
          Alcotest.test_case "signal scope fields" `Quick
            test_signal_scope_fields;
          Alcotest.test_case "signal label" `Quick test_signal_label;
          Alcotest.test_case "observer label" `Quick test_observer_label;
          Alcotest.test_case "render dot" `Quick test_render_dot;
        ] );
    ]
