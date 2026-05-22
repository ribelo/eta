open Eta

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
      ~tracer:(Tracer.as_capability tracer) ()
  in
  let expected_name = __FUNCTION__ in
  let program = [%eta.fn (Effect.pure 1)] in
  Alcotest.(check int) "value" 1 (run_ok rt program);
  let span = only_span tracer in
  Alcotest.(check string) "span name" expected_name span.name;
  match attr "loc" span with
  | Some loc -> Alcotest.(check bool) "loc recorded" true (String.contains loc '/')
  | None -> Alcotest.fail "missing loc attr"

module Auth = struct
  type t = { user : string }

  let current_user auth = auth.user
end

let current_user auth =
  [%eta.sync "auth.current_user" (auth : Auth.t) (Auth.current_user auth)]

let test_ppx_thunk_leaf () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let auth = { Auth.user = "alice" } in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  Alcotest.(check string) "value" "alice" (run_ok rt (current_user auth));
  let spans = Tracer.dump tracer in
  Alcotest.(check int) "span count" 2 (List.length spans);
  let find name = List.find (fun span -> span.Tracer.name = name) spans in
  let fn = find "Dune__exe__Test_ppx_eta.current_user" in
  let leaf = find "auth.current_user" in
  Alcotest.(check (option int)) "leaf parent" (Some fn.span_id) leaf.parent_id

let () =
  Alcotest.run "ppx_eta"
    [
      ( "ppx",
        [
          Alcotest.test_case "fn" `Quick test_ppx_fn;
          Alcotest.test_case "sync leaf" `Quick test_ppx_thunk_leaf;
        ] );
    ]
