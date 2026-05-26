module Native = Stdlib.Effect
module Deep = Stdlib.Effect.Deep
module Eta_effect = Eta.Effect

type _ Native.t += Log_info : string -> unit Native.t

let log_info msg = Native.perform (Log_info msg)

let install_log sink f =
  Deep.try_with f ()
    {
      effc =
        (fun (type a) (eff : a Native.t) ->
          match eff with
          | Log_info msg ->
              Some
                (fun (k : (a, _) Deep.continuation) ->
                  sink msg;
                  Deep.continue k ())
          | _ -> None);
    }

let log_key : (string -> unit) Eio.Fiber.key = Eio.Fiber.create_key ()

let with_log_service sink f =
  Eio.Fiber.with_binding log_key sink (fun () -> install_log sink f)

let reinstall_current f =
  match Eio.Fiber.get log_key with
  | Some sink -> install_log sink f
  | None -> failwith "Log_info service missing from Eio fiber-local storage"

let eta_log msg = Eta_effect.sync (fun () -> log_info msg)
let eta_log_reinstall msg = Eta_effect.sync (fun () -> reinstall_current (fun () -> log_info msg))

let rec cause_has_unhandled : 'err. 'err Eta.Cause.t -> bool = function
  | Eta.Cause.Die { exn = Native.Unhandled _; _ } -> true
  | Eta.Cause.Die _ | Eta.Cause.Fail _ | Eta.Cause.Interrupt _ -> false
  | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
      List.exists cause_has_unhandled causes
  | Eta.Cause.Suppressed { primary; finalizer } ->
      cause_has_unhandled primary || cause_has_unhandled finalizer

let render_cause cause =
  Format.asprintf "%a"
    (Eta.Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<typed>"))
    cause

type outcome =
  | Returned
  | Raised_unhandled
  | Raised_other of string
  | Eta_ok
  | Eta_unhandled of string
  | Eta_error of string

let outcome_status = function
  | Returned | Eta_ok -> "resolved"
  | Raised_unhandled | Eta_unhandled _ -> "unhandled"
  | Raised_other _ | Eta_error _ -> "other-error"

let outcome_detail = function
  | Returned -> "returned"
  | Raised_unhandled -> "raised Effect.Unhandled"
  | Raised_other msg -> "raised " ^ msg
  | Eta_ok -> "Runtime.run returned Exit.Ok"
  | Eta_unhandled msg -> "Runtime.run returned Exit.Error containing Effect.Unhandled: " ^ msg
  | Eta_error msg -> "Runtime.run returned Exit.Error: " ^ msg

let capture_unit f sink =
  try
    f sink;
    Returned
  with
  | Native.Unhandled _ -> Raised_unhandled
  | exn -> Raised_other (Printexc.to_string exn)

let capture_eta f sink =
  try
    match f sink with
    | Eta.Exit.Ok () -> Eta_ok
    | Eta.Exit.Error cause ->
        let msg = render_cause cause in
        if cause_has_unhandled cause then Eta_unhandled msg else Eta_error msg
  with
  | Native.Unhandled _ -> Raised_unhandled
  | exn -> Raised_other (Printexc.to_string exn)

let capture_eta_failures f sink =
  try
    match f sink with
    | Eta.Exit.Ok failures ->
        if List.exists cause_has_unhandled failures then
          Eta_unhandled
            (Printf.sprintf "Supervisor failures contained %d unhandled cause(s)"
               (List.length failures))
        else if failures = [] then Eta_ok
        else
          Eta_error
            (Printf.sprintf "Supervisor failures contained %d non-unhandled cause(s)"
               (List.length failures))
    | Eta.Exit.Error cause ->
        let msg = render_cause cause in
        if cause_has_unhandled cause then Eta_unhandled msg else Eta_error msg
  with
  | Native.Unhandled _ -> Raised_unhandled
  | exn -> Raised_other (Printexc.to_string exn)

let events_string events = String.concat "," (List.rev !events)

let run_case ~name ~expect_resolved ~expected_events ~capture f =
  let events = ref [] in
  let sink msg = events := msg :: !events in
  let outcome = capture f sink in
  let resolved = outcome_status outcome = "resolved" in
  let events_match = List.rev !events = expected_events in
  Printf.printf "case=%s status=%s events=[%s] detail=%s\n%!" name
    (outcome_status outcome) (events_string events) (outcome_detail outcome);
  if Bool.equal resolved expect_resolved && (not expect_resolved || events_match)
  then ()
  else begin
    Printf.eprintf
      "unexpected result for %s: expect_resolved=%b expected_events=[%s]\n%!"
      name expect_resolved (String.concat "," expected_events);
    exit 1
  end

let with_eta_runtime f =
  Eio_posix.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f rt

let direct_same_fiber sink =
  install_log sink (fun () -> log_info "direct")

let fiber_both_bare sink =
  Eio_posix.run @@ fun _env ->
  install_log sink (fun () ->
      Eio.Fiber.both
        (fun () -> log_info "left")
        (fun () -> log_info "right"))

let fiber_both_reinstalled sink =
  Eio_posix.run @@ fun _env ->
  with_log_service sink (fun () ->
      Eio.Fiber.both
        (fun () -> reinstall_current (fun () -> log_info "left"))
        (fun () -> reinstall_current (fun () -> log_info "right")))

let fiber_fork_bare sink =
  Eio_posix.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  install_log sink (fun () ->
      let promise, resolver = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          log_info "fork";
          Eio.Promise.resolve resolver ());
      Eio.Promise.await promise)

let fiber_fork_reinstalled sink =
  Eio_posix.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_log_service sink (fun () ->
      let promise, resolver = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          reinstall_current (fun () ->
              log_info "fork";
              Eio.Promise.resolve resolver ()));
      Eio.Promise.await promise)

let nested_switch_bare sink =
  Eio_posix.run @@ fun _env ->
  install_log sink (fun () -> Eio.Switch.run (fun _sw -> log_info "nested-switch"))

let eta_timeout_bare sink =
  with_eta_runtime @@ fun rt ->
  install_log sink (fun () ->
      Eta.Runtime.run rt
        (Eta_effect.timeout (Eta.Duration.seconds 10) (eta_log "timeout")))

let eta_timeout_leaf_reinstall sink =
  with_eta_runtime @@ fun rt ->
  with_log_service sink (fun () ->
      Eta.Runtime.run rt
        (Eta_effect.timeout (Eta.Duration.seconds 10)
           (eta_log_reinstall "timeout")))

let eta_supervisor_bare sink =
  with_eta_runtime @@ fun rt ->
  install_log sink (fun () ->
      let program =
        Eta.Supervisor.scoped
          {
            run =
              (fun (type s) sup ->
                let open Eta.Supervisor.Scope in
                let* (_left : (s, 'err, unit) Eta.Supervisor.child) =
                  start sup (lift (eta_log "supervisor-left"))
                in
                let* (_right : (s, 'err, unit) Eta.Supervisor.child) =
                  start sup (lift (eta_log "supervisor-right"))
                in
                let* () = yield in
                failures sup);
          }
      in
      Eta.Runtime.run rt program)

let eta_supervisor_leaf_reinstall sink =
  with_eta_runtime @@ fun rt ->
  with_log_service sink (fun () ->
      let program =
        Eta.Supervisor.scoped
          {
            run =
              (fun (type s) sup ->
                let open Eta.Supervisor.Scope in
                let* (_left : (s, 'err, unit) Eta.Supervisor.child) =
                  start sup (lift (eta_log_reinstall "supervisor-left"))
                in
                let* (_right : (s, 'err, unit) Eta.Supervisor.child) =
                  start sup (lift (eta_log_reinstall "supervisor-right"))
                in
                let* () = yield in
                failures sup);
          }
      in
      Eta.Runtime.run rt program)

let eta_acquire_release_bare sink =
  with_eta_runtime @@ fun rt ->
  install_log sink (fun () ->
      let resource =
        Eta_effect.acquire_release ~acquire:Eta_effect.unit ~release:(fun () ->
            eta_log "release")
      in
      Eta.Runtime.run rt
        (Eta_effect.scoped
           (Eta_effect.bind (fun () -> eta_log "body") resource)))

let () =
  run_case ~name:"direct_same_fiber_root_handler" ~expect_resolved:true
    ~expected_events:[ "direct" ] ~capture:capture_unit direct_same_fiber;
  run_case ~name:"eio_fiber_both_bare" ~expect_resolved:false
    ~expected_events:[] ~capture:capture_unit fiber_both_bare;
  run_case ~name:"eio_fiber_both_branch_reinstall" ~expect_resolved:true
    ~expected_events:[ "left"; "right" ] ~capture:capture_unit
    fiber_both_reinstalled;
  run_case ~name:"eio_fiber_fork_bare" ~expect_resolved:false
    ~expected_events:[] ~capture:capture_unit fiber_fork_bare;
  run_case ~name:"eio_fiber_fork_child_reinstall" ~expect_resolved:true
    ~expected_events:[ "fork" ] ~capture:capture_unit fiber_fork_reinstalled;
  run_case ~name:"nested_switch_run_bare" ~expect_resolved:true
    ~expected_events:[ "nested-switch" ] ~capture:capture_unit
    nested_switch_bare;
  run_case ~name:"eta_effect_timeout_bare" ~expect_resolved:true
    ~expected_events:[ "timeout" ] ~capture:capture_eta eta_timeout_bare;
  run_case ~name:"eta_effect_timeout_leaf_reinstall" ~expect_resolved:true
    ~expected_events:[ "timeout" ] ~capture:capture_eta
    eta_timeout_leaf_reinstall;
  run_case ~name:"eta_supervisor_scoped_two_children_bare"
    ~expect_resolved:false ~expected_events:[] ~capture:capture_eta_failures
    eta_supervisor_bare;
  run_case ~name:"eta_supervisor_scoped_leaf_reinstall"
    ~expect_resolved:true
    ~expected_events:[ "supervisor-left"; "supervisor-right" ]
    ~capture:capture_eta_failures eta_supervisor_leaf_reinstall;
  run_case ~name:"eta_acquire_release_body_release_bare"
    ~expect_resolved:true ~expected_events:[ "body"; "release" ]
    ~capture:capture_eta eta_acquire_release_bare;
  print_endline "p1 locality evidence complete"
