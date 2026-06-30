open Eta

module Direct_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let now = ref 0
  let root_scope = ()
  let now_ms () = !now
  let sleep duration = now := !now + Duration.to_ms duration
  let protect f = f ()
  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = failwith "Direct_runtime.await_cancel: no cancellation"
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
    | None -> failwith "Direct_runtime.await_promise: unresolved promise"

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

  let locals : (int, Runtime_contract.local_binding list) Hashtbl.t =
    Hashtbl.create 8

  let local_get local =
    match Hashtbl.find_opt locals (Runtime_contract.Backend.local_id local) with
    | None -> None
    | Some bindings ->
        List.find_map
          (Runtime_contract.Backend.local_binding_value local)
          bindings

  let local_with_binding local value f =
    let id = Runtime_contract.Backend.local_id local in
    let previous = Hashtbl.find_opt locals id in
    let stack = Option.value previous ~default:[] in
    Hashtbl.replace locals id
      (Runtime_contract.Local_binding (local, value) :: stack);
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some stack -> Hashtbl.replace locals id stack
        | None -> Hashtbl.remove locals id)
      f
end

module Direct = Runtime.Make (Direct_runtime)

let check_exit_ok test name expected = function
  | Exit.Ok actual -> Alcotest.check test name expected actual
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<direct>"))
        cause

let test_functor_runtime_runs_core_effect () =
  let rt = Direct.create () in
  Effect.pure 20
  |> Effect.map (fun n -> n + 22)
  |> Direct.run rt
  |> check_exit_ok Alcotest.int "direct runtime result" 42

let test_first_class_runtime_uses_contract_sleep () =
  Direct_runtime.now := 0;
  let rt =
    Runtime.create_with_runtime
      (module Direct_runtime : Runtime_contract.RUNTIME)
      ()
  in
  let eff = Effect.delay (Duration.ms 7) (Effect.pure "done") in
  Runtime.run rt eff |> check_exit_ok Alcotest.string "delay result" "done";
  Alcotest.(check int) "direct clock advanced" 7 (Direct_runtime.now_ms ())

let test_runtime_sleep_and_now_share_monotonic_timebase () =
  Direct_runtime.now := 10;
  let rt = Direct.create () in
  let eff =
    Effect.now
    |> Effect.bind (fun before ->
           Effect.sleep (Duration.ms 5)
           |> Effect.bind (fun () ->
                  Effect.now |> Effect.map (fun after -> (before, after))))
  in
  Direct.run rt eff
  |> check_exit_ok
       Alcotest.(pair int int)
       "runtime clock pair" (10, 15)

let test_direct_runtime_preserves_task_context () =
  let tracer = Tracer.in_memory () in
  let rt = Direct.create ~tracer:(Tracer.as_capability tracer) () in
  let eff = Effect.named "direct.span" (Effect.sync (fun () -> 1)) in
  Direct.run rt eff |> check_exit_ok Alcotest.int "span result" 1;
  match Tracer.dump tracer with
  | [ span ] ->
      Alcotest.(check string) "span name" "direct.span" span.Tracer.name
  | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

let test_expert_custom_effect_uses_runtime_contract () =
  Direct_runtime.now := 10;
  let rt = Direct.create () in
  let eff =
    Effect.Expert.make ~names:[ "expert.contract" ] @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Runtime_contract.sleep (Duration.ms 5);
    Exit.Ok (contract.Runtime_contract.now_ms ())
  in
  Direct.run rt eff |> check_exit_ok Alcotest.int "expert result" 15

let check_foreign_token_rejected name f =
  match f () with
  | () -> Alcotest.failf "%s: expected foreign token rejection" name
  | exception Invalid_argument message
    when String.equal message "Eta.Runtime_contract: foreign runtime token" ->
      ()
  | exception exn ->
      Alcotest.failf "%s: expected foreign token rejection, got %s" name
        (Printexc.to_string exn)

let runtime_contract_domain_message =
  "Eta.Runtime_contract: runtime contract APIs must be called on the domain "
  ^ "that created the contract"

let run_in_domain f =
  let domain =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      f
  in
  Domain.join domain

let test_erased_tokens_reject_foreign_runtime_contract () =
  let first =
    Runtime_contract.of_runtime
      (module Direct_runtime : Runtime_contract.RUNTIME)
  in
  let second =
    Runtime_contract.of_runtime
      (module Direct_runtime : Runtime_contract.RUNTIME)
  in
  let promise, resolver = first.Runtime_contract.create_promise () in
  check_foreign_token_rejected "resolver" (fun () ->
      second.Runtime_contract.resolve_promise resolver 1);
  check_foreign_token_rejected "promise" (fun () ->
      ignore (second.Runtime_contract.await_promise promise : int));
  let stream = first.Runtime_contract.create_stream 1 in
  check_foreign_token_rejected "stream add" (fun () ->
      second.Runtime_contract.stream_add stream 1);
  check_foreign_token_rejected "stream take" (fun () ->
      ignore (second.Runtime_contract.stream_take stream : int));
  let forked = ref false in
  check_foreign_token_rejected "scope" (fun () ->
      second.Runtime_contract.fork first.Runtime_contract.root_scope (fun () ->
          forked := true));
  Alcotest.(check bool) "foreign scope did not reach backend" false !forked;
  first.Runtime_contract.cancel_sub @@ fun cancel_context ->
  check_foreign_token_rejected "cancel context" (fun () ->
      second.Runtime_contract.cancel cancel_context Exit)

let test_erased_runtime_contract_rejects_foreign_domain_use () =
  let contract =
    Runtime_contract.of_runtime
      (module Direct_runtime : Runtime_contract.RUNTIME)
  in
  match
    run_in_domain @@ fun () ->
    try Ok (contract.Runtime_contract.now_ms ()) with
    | Invalid_argument message -> Error message
    | exn ->
        Alcotest.failf "expected Invalid_argument, got %s"
          (Printexc.to_string exn)
  with
  | Error message ->
      Alcotest.(check string)
        "cross-domain runtime contract failure"
        runtime_contract_domain_message message
  | Ok _ -> Alcotest.fail "expected cross-domain runtime contract use to fail"

let tests =
  [
    ( "Runtime contract",
      [
        Alcotest.test_case "functor runtime runs core effect" `Quick
          test_functor_runtime_runs_core_effect;
        Alcotest.test_case "first-class runtime uses contract sleep" `Quick
          test_first_class_runtime_uses_contract_sleep;
        Alcotest.test_case "sleep and now share monotonic timebase" `Quick
          test_runtime_sleep_and_now_share_monotonic_timebase;
        Alcotest.test_case "direct runtime preserves task context" `Quick
          test_direct_runtime_preserves_task_context;
        Alcotest.test_case "expert custom effect uses runtime contract" `Quick
          test_expert_custom_effect_uses_runtime_contract;
        Alcotest.test_case "erased tokens reject foreign runtime contract" `Quick
          test_erased_tokens_reject_foreign_runtime_contract;
        Alcotest.test_case "erased contract rejects cross-domain use" `Quick
          test_erased_runtime_contract_rejects_foreign_domain_use;
      ] );
  ]
