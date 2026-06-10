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
        ] );
      ( "sql_table",
        [
          Alcotest.test_case "projection" `Quick test_sql_table_projection;
          Alcotest.test_case "schema metadata" `Quick
            test_sql_table_schema_metadata;
        ] );
    ]
end
