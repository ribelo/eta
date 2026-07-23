module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe
module Runtime_contract = Eta.Runtime_contract

exception Probe_failure of string

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_exit_code code =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.set process "exitCode" code

let require condition message =
  if not condition then raise (Probe_failure message)

let nested_protect_probe () =
  Eta.Effect.Expert.make ~leaf_name:"dx-e15 jsoo nested protect probe"
    ~capabilities:[ `Concurrency ]
  @@ fun context ->
  let contract = Eta.Effect.Expert.contract context in
  let reason = Failure "nested pending cancellation" in
  let inner_returned = ref false in
  let outer_body_returned = ref false in
  let protect_returned = ref false in
  let delivered_at_depth_zero = ref false in
  contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
  (try
     contract.Runtime_contract.protect (fun () ->
         contract.Runtime_contract.protect (fun () ->
             contract.Runtime_contract.cancel cancel_context reason;
             contract.Runtime_contract.yield ();
             inner_returned := true);
         outer_body_returned := true);
     protect_returned := true
   with exn ->
     match contract.Runtime_contract.cancellation_reason exn with
     | Some actual when actual == reason -> delivered_at_depth_zero := true
     | _ -> raise exn);
  Eta.Exit.Ok
    ( !inner_returned,
      !outer_body_returned,
      !protect_returned,
      !delivered_at_depth_zero )

let sub_after_pending_probe () =
  Eta.Effect.Expert.make ~leaf_name:"dx-e15 jsoo pending sub probe"
    ~capabilities:[ `Concurrency ]
  @@ fun context ->
  let contract = Eta.Effect.Expert.contract context in
  let reason = Failure "parent pending before child" in
  let child_wait_returned = ref false in
  let delivered_at_protect_exit = ref false in
  contract.Runtime_contract.cancel_sub @@ fun parent ->
  (try
     contract.Runtime_contract.protect (fun () ->
         contract.Runtime_contract.cancel parent reason;
         contract.Runtime_contract.cancel_sub @@ fun _child ->
         contract.Runtime_contract.yield ();
         child_wait_returned := true)
   with exn ->
     match contract.Runtime_contract.cancellation_reason exn with
     | Some actual when actual == reason -> delivered_at_protect_exit := true
     | _ -> raise exn);
  Eta.Exit.Ok (!child_wait_returned, !delivered_at_protect_exit)

let probe =
  Eta.Effect.bind
    (fun nested ->
      Eta.Effect.map (fun pending_sub -> (nested, pending_sub))
        (sub_after_pending_probe ()))
    (nested_protect_probe ())

let completed = ref false

let () =
  let process = Unsafe.get Unsafe.global "process" in
  ignore
    (Unsafe.meth_call process "on"
       [|
         Unsafe.inject (Js.string "beforeExit");
         Unsafe.inject
           (Js.wrap_callback (fun _code ->
                if not !completed then (
                  set_exit_code 1;
                  log "jsoo probe: FAIL (completion sentinel not reached)")));
       |]);
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime probe ~on_result:(function
    | Eta.Exit.Ok
        ( ( inner_returned,
            outer_body_returned,
            protect_returned,
            delivered_at_depth_zero ),
          (child_wait_returned, delivered_at_protect_exit) ) ->
        (try
           require inner_returned
             "pending cancellation was delivered with protect depth two";
           require outer_body_returned
             "pending cancellation was delivered with protect depth one";
           require (not protect_returned)
             "pending cancellation was not delivered when depth returned to zero";
           require delivered_at_depth_zero
             "outer protect exit raised the wrong exception";
           require child_wait_returned
             "pending parent cancellation propagated into a sub made under protect";
           require delivered_at_protect_exit
             "pending parent cancellation disappeared after protected sub";
           log
             "jsoo nested-protect: depth=2 returned; depth=1 returned; depth=0 \
              cancelled";
           log
             "jsoo pending-parent->protected-sub: child-wait=returned; \
              protect-exit=cancelled";
           completed := true;
           log "jsoo probe: PASS"
         with exn ->
           set_exit_code 1;
           completed := true;
           log ("jsoo probe: FAIL " ^ Printexc.to_string exn))
    | Eta.Exit.Error cause ->
        set_exit_code 1;
        completed := true;
        log
          (Format.asprintf "jsoo probe: FAIL unexpected Eta exit: %a"
             (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
             cause))
