module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  open Eta

  let run_ok rt eff =
    match B.run rt eff with
    | Exit.Ok value -> value
    | Exit.Error _ -> Alcotest.fail "expected Ok"

  let only_span tracer =
    match Tracer.dump tracer with
    | [ span ] -> span
    | spans -> Alcotest.failf "expected one span, got %d" (List.length spans)

  let attr key span = List.assoc_opt key span.Tracer.attrs

  let contains haystack needle =
    let haystack_len = String.length haystack in
    let needle_len = String.length needle in
    let rec loop index =
      index + needle_len <= haystack_len
      &&
      (String.equal (String.sub haystack index needle_len) needle
       || loop (index + 1))
    in
    needle_len = 0 || loop 0

  module Q = Eta_sql

  type err =
    [ `Db of int
    | `Unavailable ]
  [@@deriving eta_error]

  let raising_payload_pp _fmt _payload = failwith "derived renderer exploded"

  type raising_err =
    [ `Custom of string [@eta.render raising_payload_pp] ]
  [@@deriving eta_error]

  [%%eta.sql.table
  type users = {
    id : int [@primary_key];
    name : string [@not_null];
    active : bool [@not_null] [@default true];
  }]

  [%%eta.sql.table
  type teams = {
    team_pk : int [@primary_key];
    team_name : string [@unique];
  }]

  [%%eta.sql.table
  type memberships = {
    membership_pk : int [@primary_key];
    membership_team : int [@references Teams.team_pk] [@on_delete "CASCADE"];
    membership_role : string [@not_null] [@default "member"];
  }]

  let test_ppx_fn () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let expected_name = __FUNCTION__ in
    let program = [%eta.fn (Effect.pure 1)] in
    Alcotest.(check int) "value" 1 (run_ok rt program);
    let span = only_span tracer in
    Alcotest.(check string) "span name" expected_name span.name;
    match attr "loc" span with
    | Some loc ->
        Alcotest.(check bool) "loc recorded" true (String.contains loc '/')
    | None -> Alcotest.fail "missing loc attr"

  module Auth = struct
    type t = { user : string }

    let current_user auth = auth.user
  end

  let current_user auth =
    [%eta.sync "auth.current_user" (Auth.current_user auth)]

  let test_ppx_thunk_leaf () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let auth = { Auth.user = "alice" } in
    Alcotest.(check string) "value" "alice" (run_ok rt (current_user auth));
    let spans = Tracer.dump tracer in
    Alcotest.(check int) "span count" 2 (List.length spans);
    let find name = List.find (fun span -> String.equal span.Tracer.name name) spans in
    let leaf = find "auth.current_user" in
    let fn =
      List.find
        (fun span ->
          not (String.equal span.Tracer.name "auth.current_user")
          && contains span.Tracer.name "current_user")
        spans
    in
    Alcotest.(check (option int)) "leaf parent" (Some fn.span_id) leaf.parent_id

  module Db = struct
    let find_ok () : (string, err) result = Ok "user:42"
    let find_err () : (string, err) result = Error (`Db 7)
    let find_raise () : (string, err) result = failwith "db exploded"
  end

  let run_result_case rt label (program : (string, err) Effect.t) =
    match B.run rt program with
    | Exit.Ok value -> `Ok value
    | Exit.Error (Cause.Fail err) -> `Fail err
    | Exit.Error (Cause.Die die) -> `Die (Printexc.to_string die.exn)
    | Exit.Error _ -> Alcotest.failf "%s: unexpected cause" label

  let test_ppx_result_parity () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let result_sugar_ok : (string, err) Effect.t =
      [%eta.result "db.find" (Db.find_ok ())]
    in
    let result_hand_ok : (string, err) Effect.t =
      Effect.fn __POS__ __FUNCTION__
        (Effect.named "db.find" (Effect.sync_result (fun () -> Db.find_ok ())))
    in
    let result_sugar_err : (string, err) Effect.t =
      [%eta.result "db.find" (Db.find_err ())]
    in
    let result_hand_err : (string, err) Effect.t =
      Effect.fn __POS__ __FUNCTION__
        (Effect.named "db.find" (Effect.sync_result (fun () -> Db.find_err ())))
    in
    let result_sugar_raise : (string, err) Effect.t =
      [%eta.result "db.find" (Db.find_raise ())]
    in
    let result_hand_raise : (string, err) Effect.t =
      Effect.fn __POS__ __FUNCTION__
        (Effect.named "db.find"
           (Effect.sync_result (fun () -> Db.find_raise ())))
    in
    let check_ok label program =
      match run_result_case rt label program with
      | `Ok value -> Alcotest.(check string) (label ^ " value") "user:42" value
      | _ -> Alcotest.failf "%s: expected Ok" label
    in
    check_ok "sugar ok" result_sugar_ok;
    check_ok "hand ok" result_hand_ok;
    let spans = Tracer.dump tracer in
    let leaf_spans =
      List.filter (fun span -> String.equal span.Tracer.name "db.find") spans
    in
    Alcotest.(check int) "ok leaf spans" 2 (List.length leaf_spans);
    (* loc is attached by Effect.fn / here_attr on the outer span, not the leaf. *)
    let loc_spans =
      List.filter
        (fun span ->
          match attr "loc" span with
          | Some loc -> String.contains loc '/'
          | None -> false)
        spans
    in
    Alcotest.(check bool) "source loc present" true (List.length loc_spans >= 2);
    (match
       ( run_result_case rt "sugar err" result_sugar_err,
         run_result_case rt "hand err" result_hand_err )
     with
     | `Fail (`Db 7), `Fail (`Db 7) -> ()
     | _ -> Alcotest.fail "expected matching Db 7 typed failures");
    (match
       ( run_result_case rt "sugar raise" result_sugar_raise,
         run_result_case rt "hand raise" result_hand_raise )
     with
     | `Die sugar, `Die hand ->
         Alcotest.(check string)
           "defect message" "Failure(\"db exploded\")" sugar;
         Alcotest.(check string) "hand defect message" sugar hand
     | _ -> Alcotest.fail "expected matching Die defects")

  let test_eta_error_span_status () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    let before = Effect.named "db.save.before" (Effect.fail (`Db 7)) in
    let after =
      Effect.named ~error_pp:pp_err "db.save" (Effect.fail (`Db 7))
    in
    let run label program =
      match B.run rt program with
      | Exit.Error (Cause.Fail (`Db 7)) -> ()
      | _ -> Alcotest.failf "expected Db 7 typed failure from %s" label
    in
    run "default" before;
    run "derived" after;
    let spans = Tracer.dump tracer in
    let find name =
      List.find (fun span -> String.equal span.Tracer.name name) spans
    in
    let status name =
      match (find name).status with
      | Tracer.Error message -> message
      | _ -> Alcotest.failf "expected error span status for %s" name
    in
    Alcotest.(check string)
      "default status" "<typed failure>" (status "db.save.before");
    Alcotest.(check string) "derived status" "db:7" (status "db.save")

  let test_eta_error_raising_renderer_becomes_defect () =
    B.with_traced_runtime @@ fun _ctx rt _tracer ->
    let program =
      Effect.named ~error_pp:pp_raising_err "db.save"
        (Effect.fail (`Custom "payload"))
    in
    match B.run rt program with
    | Exit.Error (Cause.Die die) ->
        Alcotest.(check string)
          "defect message" "Failure(\"derived renderer exploded\")"
          (Printexc.to_string die.exn)
    | Exit.Error (Cause.Fail _) ->
        Alcotest.fail "expected defect from raising derived renderer"
    | Exit.Error _ -> Alcotest.fail "expected die defect"
    | Exit.Ok _ -> Alcotest.fail "expected failure"

  let%eta let_eta_add x =
    Effect.pure (x + 1)

  let eta_trace_add x = Effect.pure (x + 1) [@@eta.trace]

  let hand_fn_add x = Effect.fn __POS__ __FUNCTION__ (Effect.pure (x + 1))

  let test_let_eta_and_attr_parity () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    Alcotest.(check int) "let%eta value" 2 (run_ok rt (let_eta_add 1));
    Alcotest.(check int) "attr value" 3 (run_ok rt (eta_trace_add 2));
    Alcotest.(check int) "hand value" 4 (run_ok rt (hand_fn_add 3));
    let spans = Tracer.dump tracer in
    Alcotest.(check int) "three spans" 3 (List.length spans);
    List.iter
      (fun span ->
        match attr "loc" span with
        | Some loc ->
            Alcotest.(check bool) "loc present" true (String.contains loc '/')
        | None -> Alcotest.fail "missing loc attr")
      spans

  let%eta rec countdown n =
    if n <= 0 then Effect.pure 0
    else
      let open Syntax in
      let* _ = Effect.pure () in
      countdown (n - 1)

  let test_let_eta_rec_spans () =
    B.with_traced_runtime @@ fun _ctx rt tracer ->
    Alcotest.(check int) "countdown" 0 (run_ok rt (countdown 3));
    let spans = Tracer.dump tracer in
    (* Wrapper is inside the recursive body: each entry re-enters fn. *)
    Alcotest.(check int) "per-call spans" 4 (List.length spans);
    List.iter
      (fun span ->
        Alcotest.(check bool)
          "span name ends with countdown" true
          (let name = span.Tracer.name in
           let suffix = "countdown" in
           let nlen = String.length name in
           let slen = String.length suffix in
           nlen >= slen
           && String.equal (String.sub name (nlen - slen) slen) suffix))
      spans

  let test_sql_table_projection () =
    let select =
      Q.Select.(
        from Users.table Users.all
        |> where Q.Expr.(eq Users.active true)
        |> compile)
    in
    Alcotest.(check string)
      "select sql"
      "SELECT \"users\".\"id\", \"users\".\"name\", \"users\".\"active\" FROM \
       \"users\" WHERE (\"users\".\"active\" = ?)"
      (Q.Compiled.select_sql select);
    Alcotest.(check int) "params" 1
      (List.length (Q.Compiled.select_params select))

  let test_sql_table_schema_metadata () =
    let sql = Q.Eta_schema.to_sql Memberships.schema in
    Alcotest.(check bool) "primary key" true
      (contains sql "\"membership_pk\" INTEGER PRIMARY KEY");
    Alcotest.(check bool) "foreign key" true
      (contains sql "REFERENCES \"teams\" (\"team_pk\")");
    Alcotest.(check bool) "on delete" true (contains sql "ON DELETE CASCADE");
    Alcotest.(check bool) "default" true
      (contains sql "\"membership_role\" TEXT NOT NULL DEFAULT 'member'")

  let tests =
    [
      ( "ppx",
        [
          Alcotest.test_case "fn" `Quick test_ppx_fn;
          Alcotest.test_case "sync leaf" `Quick test_ppx_thunk_leaf;
          Alcotest.test_case "result leaf parity" `Quick test_ppx_result_parity;
          Alcotest.test_case "let%eta / [@@eta.trace] parity" `Quick
            test_let_eta_and_attr_parity;
          Alcotest.test_case "let%eta rec per-call spans" `Quick
            test_let_eta_rec_spans;
          Alcotest.test_case "eta_error span status" `Quick
            test_eta_error_span_status;
          Alcotest.test_case "eta_error raising renderer" `Quick
            test_eta_error_raising_renderer_becomes_defect;
        ] );
      ( "sql_table",
        [
          Alcotest.test_case "projection" `Quick test_sql_table_projection;
          Alcotest.test_case "schema metadata" `Quick
            test_sql_table_schema_metadata;
        ] );
    ]
end
