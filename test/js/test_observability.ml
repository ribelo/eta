open Eta_js
open Eta_js_test

let test_log_no_crash () =
  let runtime = Runtime.create () in
  Js.Promise.then_
    (fun exit ->
      (match exit with
      | Exit.Ok () -> ()
      | _ -> fail "log_no_crash" "expected ok" |> raise);
      Js.Promise.resolve ())
    (Runtime.run_promise runtime (Effect.log "hello"))

let test_log_level () =
  let runtime = Runtime.create () in
  let p1 =
    Js.Promise.then_
      (fun exit ->
        (match exit with
        | Exit.Ok () -> ()
        | _ -> fail "log_debug" "expected ok" |> raise);
        Js.Promise.resolve ())
      (Runtime.run_promise runtime (Effect.log_debug "debug msg"))
  in
  let p2 =
    Js.Promise.then_
      (fun () ->
        Js.Promise.then_
          (fun exit ->
            (match exit with
            | Exit.Ok () -> ()
            | _ -> fail "log_info" "expected ok" |> raise);
            Js.Promise.resolve ())
          (Runtime.run_promise runtime (Effect.log_info "info msg")))
      p1
  in
  let p3 =
    Js.Promise.then_
      (fun () ->
        Js.Promise.then_
          (fun exit ->
            (match exit with
            | Exit.Ok () -> ()
            | _ -> fail "log_warning" "expected ok" |> raise);
            Js.Promise.resolve ())
          (Runtime.run_promise runtime (Effect.log_warning "warn msg")))
      p2
  in
  Js.Promise.then_
    (fun () ->
      Js.Promise.then_
        (fun exit ->
          (match exit with
          | Exit.Ok () -> ()
          | _ -> fail "log_error" "expected ok" |> raise);
          Js.Promise.resolve ())
        (Runtime.run_promise runtime (Effect.log_error "error msg")))
    p3

let test_named_no_crash () =
  let runtime = Runtime.create () in
  Js.Promise.then_
    (fun exit ->
      (match exit with
      | Exit.Ok actual ->
          (match actual with
          | 42 -> ()
          | _ -> fail "named" "expected 42" |> raise)
      | _ -> fail "named" "expected ok" |> raise);
      Js.Promise.resolve ())
    (Runtime.run_promise runtime (Effect.named "my_effect" (Effect.pure 42)))

let test_annotate_no_crash () =
  let runtime = Runtime.create () in
  Js.Promise.then_
    (fun exit ->
      (match exit with
      | Exit.Ok actual ->
          (match actual with
          | 42 -> ()
          | _ -> fail "annotate" "expected 42" |> raise)
      | _ -> fail "annotate" "expected ok" |> raise);
      Js.Promise.resolve ())
    (Runtime.run_promise runtime
       (Effect.annotate "key" "value" (Effect.pure 42)))

let test_annotate_all_no_crash () =
  let runtime = Runtime.create () in
  Js.Promise.then_
    (fun exit ->
      (match exit with
      | Exit.Ok actual ->
          (match actual with
          | 42 -> ()
          | _ -> fail "annotate_all" "expected 42" |> raise)
      | _ -> fail "annotate_all" "expected ok" |> raise);
      Js.Promise.resolve ())
    (Runtime.run_promise runtime
       (Effect.annotate_all [ ("k1", "v1"); ("k2", "v2") ] (Effect.pure 42)))

let test_suppress_observability () =
  let runtime = Runtime.create () in
  Js.Promise.then_
    (fun exit ->
      (match exit with
      | Exit.Ok actual ->
          (match actual with
          | 42 -> ()
          | _ -> fail "suppress_observability" "expected 42" |> raise)
      | _ -> fail "suppress_observability" "expected ok" |> raise);
      Js.Promise.resolve ())
    (Runtime.run_promise runtime
       (Effect.suppress_observability (Effect.pure 42)))

let tests =
  [
    ("log_no_crash", test_log_no_crash);
    ("log_level", test_log_level);
    ("named_no_crash", test_named_no_crash);
    ("annotate_no_crash", test_annotate_no_crash);
    ("annotate_all_no_crash", test_annotate_all_no_crash);
    ("suppress_observability", test_suppress_observability);
  ]
