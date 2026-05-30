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

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0

let test_generated_projection () =
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
  Alcotest.(check int) "params" 1 (List.length (Q.Compiled.select_params select))

let test_generated_schema_metadata () =
  let sql = Q.Eta_schema.to_sql Memberships.schema in
  Alcotest.(check bool)
    "primary key" true
    (contains sql "\"membership_pk\" INTEGER PRIMARY KEY");
  Alcotest.(check bool)
    "foreign key" true
    (contains sql "REFERENCES \"teams\" (\"team_pk\")");
  Alcotest.(check bool) "on delete" true (contains sql "ON DELETE CASCADE");
  Alcotest.(check bool)
    "default" true
    (contains sql "\"membership_role\" TEXT NOT NULL DEFAULT \'member\'")

let () =
  Alcotest.run "ppx_eta.sql_table"
    [
      ( "sql_table",
        [
          Alcotest.test_case "projection" `Quick test_generated_projection;
          Alcotest.test_case "schema metadata" `Quick
            test_generated_schema_metadata;
        ] );
    ]
