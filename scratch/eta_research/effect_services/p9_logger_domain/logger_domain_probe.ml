module L = Logger_effect_probe.Logger_service

type result = Pass | Fail of string

let string_of_path = function
  | L.Handler -> "handler"
  | L.Fiber_local_fallback -> "fiber-local-fallback"
  | L.Domain_local_fallback -> "domain-local-fallback"

let bodies records = List.map (fun (r : L.record) -> r.body) records
let paths records = List.map (fun (r : L.record) -> string_of_path r.path) records
let domain_ids records = List.map (fun (r : L.record) -> r.domain_id) records

let expect label ok detail =
  let status = if ok then "PASS" else "FAIL" in
  Printf.printf "case=%s status=%s %s\n%!" label status detail;
  if ok then Pass else Fail detail

let check_records label sink expected_bodies expected_paths =
  let records = L.dump sink in
  let actual_bodies = bodies records in
  let actual_paths = paths records in
  expect label
    (actual_bodies = expected_bodies && actual_paths = expected_paths)
    (Printf.sprintf "bodies=[%s] paths=[%s] domains=[%s]"
       (String.concat "," actual_bodies)
       (String.concat "," actual_paths)
       (String.concat "," (List.map string_of_int (domain_ids records))))

let check_records_paths_in label sink expected_bodies allowed_paths =
  let records = L.dump sink in
  let actual_bodies = bodies records in
  let actual_paths = paths records in
  let paths_allowed =
    List.for_all (fun path -> List.mem path allowed_paths) actual_paths
  in
  expect label
    (actual_bodies = expected_bodies && paths_allowed)
    (Printf.sprintf "bodies=[%s] paths=[%s] allowed=[%s] domains=[%s]"
       (String.concat "," actual_bodies)
       (String.concat "," actual_paths)
       (String.concat "," allowed_paths)
       (String.concat "," (List.map string_of_int (domain_ids records))))

let expect_not_configured label f =
  match f () with
  | () -> expect label false "expected Not_configured but call returned"
  | exception L.Not_configured -> expect label true "raised=Not_configured"
  | exception exn ->
      expect label false
        (Printf.sprintf "expected Not_configured got=%s" (Printexc.to_string exn))

let same_domain_handler () =
  let sink = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  L.Runtime.run sink (fun () -> L.info "root");
  check_records "same_domain_handler" sink [ "root" ] [ "handler" ]

let raw_eio_fiber_fallback () =
  let sink = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  L.Runtime.run sink (fun () ->
      Eio.Fiber.both
        (fun () -> L.info "left")
        (fun () -> L.info "right"));
  check_records_paths_in "raw_eio_fiber_does_not_break_logger" sink
    [ "left"; "right" ] [ "handler"; "fiber-local-fallback" ]

let runtime_owned_eio_both_handler () =
  let sink = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  L.Runtime.run sink (fun () ->
      L.Runtime.both
        (fun () -> L.info "owned-left")
        (fun () -> L.info "owned-right"));
  check_records "runtime_owned_eio_both_handler" sink
    [ "owned-left"; "owned-right" ] [ "handler"; "handler" ]

let raw_domain_fallback () =
  let sink = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  let child_result =
    L.Runtime.run sink (fun () ->
        let domain =
          (Domain.spawn
             [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
            (fun () ->
              try
                L.info "raw-domain";
                "logged"
              with L.Not_configured -> "missing")
        in
        Domain.join domain)
  in
  let result =
    check_records "raw_domain_fallback" sink [ "raw-domain" ]
      [ "domain-local-fallback" ]
  in
  match result with
  | Pass when child_result = "logged" -> Pass
  | Pass -> Fail ("child_result=" ^ child_result)
  | Fail _ as fail -> fail

let runtime_owned_domain_handler () =
  let sink = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  L.Runtime.run sink (fun () ->
      let domain = L.Runtime.spawn_domain (fun () -> L.info "owned-domain") in
      Domain.join domain);
  let records = L.dump sink in
  let parent_domain = (Domain.self () :> int) in
  let different_domain =
    match records with
    | [ r ] -> r.domain_id <> parent_domain
    | _ -> false
  in
  let result =
    check_records "runtime_owned_domain_handler" sink [ "owned-domain" ]
      [ "handler" ]
  in
  match result with
  | Pass when different_domain -> Pass
  | Pass -> Fail "domain id did not prove cross-domain execution"
  | Fail _ as fail -> fail

let outside_runtime_fails_loudly () =
  expect_not_configured "outside_runtime_fails_loudly" (fun () ->
      L.info "outside")

let nested_runtime_scoped () =
  let outer = L.create_sink () in
  let inner = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  L.Runtime.run outer (fun () ->
      L.info "outer-1";
      L.Runtime.run inner (fun () -> L.info "inner");
      L.info "outer-2");
  match
    ( check_records "nested_runtime_outer" outer [ "outer-1"; "outer-2" ]
        [ "handler"; "handler" ],
      check_records "nested_runtime_inner" inner [ "inner" ] [ "handler" ] )
  with
  | Pass, Pass -> Pass
  | Fail msg, _ | _, Fail msg -> Fail msg

let sibling_not_hijacked_by_nested_runtime () =
  let outer = L.create_sink () in
  let inner = L.create_sink () in
  Eio_posix.run @@ fun _env ->
  L.Runtime.run outer (fun () ->
      Eio.Fiber.both
        (fun () ->
          L.Runtime.run inner (fun () ->
              L.info "inner-1";
              Eio.Fiber.yield ();
              L.info "inner-2"))
        (fun () ->
          Eio.Fiber.yield ();
          L.info "outer-sibling"));
  match
    ( check_records_paths_in "sibling_outer_not_hijacked" outer
        [ "outer-sibling" ] [ "handler"; "fiber-local-fallback" ],
      check_records "sibling_inner" inner [ "inner-1"; "inner-2" ]
        [ "handler"; "handler" ] )
  with
  | Pass, Pass -> Pass
  | Fail msg, _ | _, Fail msg -> Fail msg

type _ Effect.t += Fake_logger : string -> unit Effect.t

let fake_handler_cannot_intercept () =
  let handled = ref false in
  let result =
    try
      Stdlib.Effect.Deep.try_with
        (fun () -> L.info "fake")
        ()
        {
          effc =
            (fun (type a) (eff : a Effect.t) ->
              match eff with
              | Fake_logger _ ->
                  Some
                    (fun (k : (a, _) Effect.Deep.continuation) ->
                      handled := true;
                      Effect.Deep.continue k ())
              | _ -> None);
        };
      "returned"
    with L.Not_configured -> "not-configured"
  in
  expect "fake_handler_cannot_intercept"
    (result = "not-configured" && not !handled)
    (Printf.sprintf "result=%s fake_handled=%b" result !handled)

let () =
  let results =
    [
      same_domain_handler ();
      raw_eio_fiber_fallback ();
      runtime_owned_eio_both_handler ();
      raw_domain_fallback ();
      runtime_owned_domain_handler ();
      outside_runtime_fails_loudly ();
      nested_runtime_scoped ();
      sibling_not_hijacked_by_nested_runtime ();
      fake_handler_cannot_intercept ();
    ]
  in
  let failures =
    List.filter_map (function Pass -> None | Fail msg -> Some msg) results
  in
  match failures with
  | [] -> print_endline "logger domain probe passed"
  | failures ->
      List.iter (Printf.eprintf "failure: %s\n%!") failures;
      exit 1
