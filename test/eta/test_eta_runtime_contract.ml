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
    if Stdlib.Queue.is_empty stream then failwith "Direct_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason _ = None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn

  let locals : (int, Obj.t list) Hashtbl.t = Hashtbl.create 8

  let local_get local =
    match Hashtbl.find_opt locals (Runtime_contract.Backend.local_id local) with
    | Some (value :: _) -> Some (Obj.obj value)
    | Some [] | None -> None

  let local_with_binding local value f =
    let id = Runtime_contract.Backend.local_id local in
    let previous = Hashtbl.find_opt locals id in
    let stack = Option.value previous ~default:[] in
    Hashtbl.replace locals id (Obj.repr value :: stack);
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
