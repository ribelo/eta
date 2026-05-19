open Effet

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let only_span tracer =
  match Tracer.dump tracer with
  | [ span ] -> span
  | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

let attr key span = List.assoc_opt key span.Tracer.attrs

let test_ppx_fn () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~env:() ()
  in
  let expected_name = __FUNCTION__ in
  let program = [%effet.fn (Effect.pure 1)] in
  Alcotest.(check int) "value" 1 (run_ok rt program);
  let span = only_span tracer in
  Alcotest.(check string) "span name" expected_name span.name;
  match attr "loc" span with
  | Some loc -> Alcotest.(check bool) "loc recorded" true (String.contains loc '/')
  | None -> Alcotest.fail "missing loc attr"

let () =
  Alcotest.run "ppx_effet"
    [ ("ppx", [ Alcotest.test_case "fn" `Quick test_ppx_fn ]) ]
