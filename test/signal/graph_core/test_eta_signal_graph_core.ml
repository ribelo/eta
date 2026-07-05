module Core = Eta_signal_graph_core
module Id = Eta_signal_id

module Direct_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let root_scope = ()
  let now_ms () = 0
  let sleep _duration = ()
  let protect f = f ()
  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = failwith "Direct_runtime.await_cancel"
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    match !resolver with
    | Some _ -> invalid_arg "Direct_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    match !promise with
    | Some value -> value
    | None -> failwith "Direct_runtime.await_promise: unresolved"

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Direct_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason _ = None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let current_fiber_id () = 0
  let with_fiber_identity f = f ()

  let locals : (int, Eta.Runtime_contract.local_binding list) Hashtbl.t =
    Hashtbl.create 8

  let local_get local =
    match
      Hashtbl.find_opt locals
        (Eta.Runtime_contract.Backend.local_id local)
    with
    | None -> None
    | Some bindings ->
        List.find_map
          (Eta.Runtime_contract.Backend.local_binding_value local)
          bindings

  let local_with_binding local value f =
    let id = Eta.Runtime_contract.Backend.local_id local in
    let previous = Hashtbl.find_opt locals id in
    let stack = Option.value previous ~default:[] in
    Hashtbl.replace locals id
      (Eta.Runtime_contract.Local_binding (local, value) :: stack);
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some stack -> Hashtbl.replace locals id stack
        | None -> Hashtbl.remove locals id)
      f
end

module Direct = Eta.Runtime.Make (Direct_runtime)

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

let with_lane core f =
  let runtime = Direct.create () in
  match
    Direct.run runtime
      (Core.with_lane_access core
         ~leaf_name:"test_eta_signal_graph_core"
         ~depth_local:(Eta.Runtime_contract.create_local ())
         ~hooks:
           {
             Core.note_waiter_enqueued = ignore;
             note_waiter_compaction = ignore;
           }
         ~after_acquired:(fun () -> Eta.Effect.unit)
         f)
  with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.fail "unexpected lane access failure"

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
  with_lane core (fun lane ->
      Core.bump_counter core lane Core.Recompute_count;
      Alcotest.(check int) "bumped" 1
        (Core.counter core Core.Recompute_count);
      Core.set_counter core Core.Recompute_count max_int;
      Core.bump_counter core lane Core.Recompute_count;
      Alcotest.(check int) "saturated" max_int
        (Core.counter core Core.Recompute_count))

let test_necessary_id_updates_count_transitions () =
  let core = Core.create () in
  with_lane core (fun lane ->
      Core.update_necessary_ids core lane (signal_set [ 1; 2 ]);
      Alcotest.(check int) "became necessary first" 2
        (Core.counter core Core.Nodes_became_necessary);
      Alcotest.(check int) "became unnecessary first" 0
        (Core.counter core Core.Nodes_became_unnecessary);
      Core.update_necessary_ids core lane (signal_set [ 2; 3; 4 ]);
      Alcotest.(check int) "became necessary second" 4
        (Core.counter core Core.Nodes_became_necessary);
      Alcotest.(check int) "became unnecessary second" 1
        (Core.counter core Core.Nodes_became_unnecessary))

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
