module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let _backend_name = B.name

  module Value = struct
    type t =
      | Null
      | Int of int
      | Int64 of int64
      | Float of float
      | String of string
      | Bool of bool
      | Bytes of bytes

    let int value = Int value
    let int64 value = Int64 value
    let float value = Float value
    let string value = String value
    let bool value = Bool value
    let bytes value = Bytes value

    let to_int = function Int value -> Some value | _ -> None
    let to_int64 = function Int64 value -> Some value | _ -> None
    let to_string_value = function String value -> Some value | _ -> None
    let to_bool = function Bool value -> Some value | _ -> None
    let to_float = function Float value -> Some value | _ -> None
    let to_bytes = function Bytes value -> Some value | _ -> None

    let to_string = function
      | Null -> "NULL"
      | Int value -> string_of_int value
      | Int64 value -> Int64.to_string value
      | Float value -> Eta_sql_dsl.quote_float value
      | String value -> value
      | Bool value -> string_of_bool value
      | Bytes value -> Bytes.to_string value

    let equal left right =
      match (left, right) with
      | Null, Null -> true
      | Int left, Int right -> Int.equal left right
      | Int64 left, Int64 right -> Int64.equal left right
      | Float left, Float right -> Float.equal left right
      | String left, String right -> String.equal left right
      | Bool left, Bool right -> Bool.equal left right
      | Bytes left, Bytes right -> Bytes.equal left right
      | _ -> false
  end

  module Row = Eta_sql_dsl.Row.Make (Value)

  module Backend = struct
    type value = Value.t
    type row = unit
    type error = string

    exception Error of error

    type 'a typ = {
      value : 'a -> value;
      decode : row -> int -> 'a;
      sql_type : string;
    }

    let decode_unavailable _ _ =
      invalid_arg "eta_sql_common_tests: row decoding is not used"

    let typ sql_type value = { value; decode = decode_unavailable; sql_type }
    let int = typ "INTEGER" Value.int
    let int64 = typ "INTEGER" Value.int64
    let bool = typ "INTEGER" Value.bool
    let float = typ "REAL" Value.float
    let text = typ "TEXT" Value.string

    let nullable inner =
      {
        value = (function None -> Value.Null | Some value -> inner.value value);
        decode = decode_unavailable;
        sql_type = inner.sql_type;
      }

    let invalid_query message = "invalid query: " ^ message
    let module_name = "Eta_sql_dsl_test"
    let value_to_string = Value.to_string

    let value_to_sql_literal = function
      | Value.Null -> "NULL"
      | Int value -> string_of_int value
      | Int64 value -> Int64.to_string value
      | Float value -> Eta_sql_dsl.quote_float value
      | String value -> Eta_sql_dsl.quote_text value
      | Bool true -> "1"
      | Bool false -> "0"
      | Bytes value -> Eta_sql_dsl.quote_blob value
  end

  module Q = Eta_sql_dsl.Make (Backend)

  let p1 column = Q.Projection.one column

  let read_file path =
    let input = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> really_input_string input (in_channel_length input))

  let rec find_sub_from haystack ~needle index =
    let haystack_len = String.length haystack in
    let needle_len = String.length needle in
    if index + needle_len > haystack_len then None
    else if String.sub haystack index needle_len = needle then Some index
    else find_sub_from haystack ~needle (index + 1)

  let find_sub haystack ~needle = find_sub_from haystack ~needle 0
  let contains_sub haystack ~needle = Option.is_some (find_sub haystack ~needle)

  let find_source_file path =
    let candidates =
      [
        Filename.concat "../../../.." path;
        Filename.concat "../../../../.." path;
        path;
        Filename.concat ".." path;
        Filename.concat "../.." path;
        Filename.concat "../../.." path;
      ]
    in
    match List.find_opt Sys.file_exists candidates with
    | Some path -> path
    | None -> Alcotest.failf "could not locate %s from %s" path (Sys.getcwd ())

  module Users = struct
    module T = Q.Table.Make (struct
      let name = "users"
    end)

    include T

    let id = column "id" Q.int
    let name = column "name" Q.text
    let active = column "active" Q.bool
    let status = column "status" Q.text
    let nickname = column "nickname" (Q.nullable Q.text)
  end

  module Posts = struct
    module T = Q.Table.Make (struct
      let name = "posts"
    end)

    include T

    let id = column "id" Q.int
    let author_id = column "author_id" Q.int
    let title = column "title" Q.text
  end

  module Items = struct
    module T = Q.Table.Make (struct
      let name = "items"
    end)

    include T

    let id = column "id" Q.int
    let width = column "width" Q.int
    let height = column "height" Q.int
  end

  module Students = struct
    module T = Q.Table.Make (struct
      let name = "students"
    end)

    include T

    let name = column "name" Q.text
    let score = column "score" Q.int
  end

  let test_render_stable_sql () =
    let query =
      Q.Select.(
        from Users.table Q.Projection.(t2 (p1 Users.id) (p1 Users.name))
        |> where Q.Expr.(and_ (gt Users.id 10) (like Users.name "A%"))
        |> order_by ~desc:true Users.name
        |> limit 1)
    in
    Alcotest.(check string) "rendered select"
      "SELECT \"users\".\"id\", \"users\".\"name\" FROM \"users\" WHERE ((\"users\".\"id\" > ?) AND (\"users\".\"name\" LIKE ?)) ORDER BY \"users\".\"name\" DESC LIMIT 1"
      (Q.Select.to_sql query)

  let test_empty_in_values_renders_false_predicate () =
    let query =
      Q.Select.(
        from Users.table Q.Projection.(one Users.name)
        |> where Q.Expr.(in_values Users.status [])
        |> order_by Users.id)
    in
    Alcotest.(check string) "empty IN SQL"
      "SELECT \"users\".\"name\" FROM \"users\" WHERE 0 ORDER BY \"users\".\"id\" ASC"
      (Q.Select.to_sql query)

  let test_in_select_rejects_multi_column_projection () =
    let two_column_int_select =
      Q.Select.(
        from Users.table
          Q.Projection.(
            t2 (p1 Users.id) (p1 Users.active)
            |> map (fun (id, _active) -> id))
        |> compile)
    in
    match
      Q.Select.(
        from Users.table Q.Projection.(one Users.name)
        |> where Q.Expr.(in_select Users.id two_column_int_select)
        |> to_sql)
    with
    | _ -> Alcotest.fail "multi-column IN subquery unexpectedly rendered"
    | exception Backend.Error error ->
        Alcotest.(check string) "message"
          "invalid query: Expr.in_select requires a one-column subquery"
          error

  let test_invalid_query_errors () =
    match Q.Insert.(into Users.table |> compile) with
    | _ -> Alcotest.fail "empty insert unexpectedly compiled"
    | exception Backend.Error error ->
        Alcotest.(check string) "message"
          "invalid query: INSERT requires at least one value"
          error

  let test_value_and_row_helpers () =
    let row =
      [
        ("id", Value.int 42);
        ("name", Value.string "Ada");
        ("active", Value.bool true);
        ("score", Value.float 3.5);
        ("payload", Value.bytes (Bytes.of_string "abc"));
      ]
    in
    Alcotest.(check (option int)) "row int" (Some 42) (Row.int "id" row);
    Alcotest.(check (option string)) "row string" (Some "Ada")
      (Row.string "name" row);
    Alcotest.(check (option bool)) "row bool" (Some true) (Row.bool "active" row);
    Alcotest.(check (option (float 0.0001))) "row float" (Some 3.5)
      (Row.float "score" row);
    Alcotest.(check (list string)) "fields"
      [ "id"; "name"; "active"; "score"; "payload" ]
      (Row.fields row);
    Alcotest.(check bool) "value equality" true
      (Value.equal (Value.string "abc") (Value.string "abc"))

  let test_compiled_type_bypass () =
    let query =
      Q.Select.(
        from Users.table Q.Projection.(one Users.id)
        |> where Q.Expr.(eq Users.id 1)
        |> compile)
    in
    Alcotest.(check string) "compiled SQL accessor"
      "SELECT \"users\".\"id\" FROM \"users\" WHERE (\"users\".\"id\" = ?)"
      (Q.Compiled.select_sql query)

  let test_sql_dsl_builders_do_not_append_single_items_source () =
    let source = read_file (find_source_file "lib/sql_dsl/eta_sql_dsl_query.ml") in
    [
      "query.ctes @ [";
      "query.group_by @ [";
      "query.order_by @ [";
      "query.values @ [";
      "query.sets @ [";
      "params := !params @";
    ]
    |> List.iter (fun needle ->
           Alcotest.(check bool) needle false (contains_sub source ~needle))

  let test_expr_operator_rendering () =
    let check label expected predicate =
      let query =
        Q.Select.(
          from Items.table Q.Projection.(one Items.id)
          |> where predicate)
      in
      Alcotest.(check string) label expected (Q.Select.to_sql query)
    in
    check "add"
      "SELECT \"items\".\"id\" FROM \"items\" WHERE (\"items\".\"width\" < (\"items\".\"height\" + ?))"
      Q.Expr.(
        lt_expr (col Items.width) (add Q.Numeric.int (col Items.height) (int_lit 5)));
    check "sub"
      "SELECT \"items\".\"id\" FROM \"items\" WHERE ((\"items\".\"width\" - ?) = \"items\".\"height\")"
      Q.Expr.(
        eq_expr (sub Q.Numeric.int (col Items.width) (int_lit 3)) (col Items.height));
    check "mul"
      "SELECT \"items\".\"id\" FROM \"items\" WHERE ((\"items\".\"height\" * ?) > \"items\".\"width\")"
      Q.Expr.(
        gt_expr (mul Q.Numeric.int (col Items.height) (int_lit 2)) (col Items.width));
    check "div"
      "SELECT \"items\".\"id\" FROM \"items\" WHERE ((\"items\".\"width\" / ?) = ?)"
      Q.Expr.(
        eq_expr (div Q.Numeric.int (col Items.width) (int_lit 2)) (int_lit 5))

  let test_case_expression_rendering () =
    let grade =
      Q.Expr.(
        case
          [
            (gt Students.score 90, text_lit "A");
            (gt Students.score 80, text_lit "B");
          ]
          ~default:(text_lit "C"))
    in
    let query =
      Q.Select.(
        from Students.table
          Q.Projection.(t2 (p1 Students.name) (expr ~as_:"grade" grade)))
    in
    Alcotest.(check string) "case"
      "SELECT \"students\".\"name\", CASE WHEN (\"students\".\"score\" > ?) THEN ? WHEN (\"students\".\"score\" > ?) THEN ? ELSE ? END AS \"grade\" FROM \"students\""
      (Q.Select.to_sql query)

  let test_schema_ddl_quotes_default_literal () =
    let schema =
      Q.Eta_schema.(
        create_table Users.table
          [
            column ~primary_key:true Users.id;
            column ~not_null:true ~default:"0; DROP TABLE users; --" Users.name;
            column Users.active;
            column Users.status;
            column Users.nickname;
          ]
        |> compile)
    in
    Alcotest.(check string) "schema DDL quotes default literal"
      "CREATE TABLE \"users\" (\"id\" INTEGER PRIMARY KEY, \"name\" TEXT NOT NULL DEFAULT '0; DROP TABLE users; --', \"active\" INTEGER, \"status\" TEXT, \"nickname\" TEXT)"
      (Q.Compiled.schema_sql schema)

  let test_schema_reference_action_normalization () =
    let schema =
      Q.Eta_schema.(
        create_table Posts.table
          [
            column ~primary_key:true Posts.id;
            column
              ~references:
                (references ~on_delete:"  set null\t" ~on_update:"no action\n"
                   Users.id)
              Posts.author_id;
            column Posts.title;
          ]
        |> compile)
    in
    Alcotest.(check string) "reference actions are canonicalized"
      "CREATE TABLE \"posts\" (\"id\" INTEGER PRIMARY KEY, \"author_id\" INTEGER REFERENCES \"users\" (\"id\") ON DELETE SET NULL ON UPDATE NO ACTION, \"title\" TEXT)"
      (Q.Compiled.schema_sql schema)

  let tests =
    [
      ( "SQL DSL",
        [
          Alcotest.test_case "render stable SQL" `Quick test_render_stable_sql;
          Alcotest.test_case "empty in values is false predicate" `Quick
            test_empty_in_values_renders_false_predicate;
          Alcotest.test_case "in_select rejects multi-column subquery" `Quick
            test_in_select_rejects_multi_column_projection;
          Alcotest.test_case "invalid query errors" `Quick test_invalid_query_errors;
          Alcotest.test_case "value and row helpers" `Quick test_value_and_row_helpers;
          Alcotest.test_case "compiled type bypass" `Quick test_compiled_type_bypass;
          Alcotest.test_case "builders avoid append hotspots" `Quick
            test_sql_dsl_builders_do_not_append_single_items_source;
          Alcotest.test_case "expr operator rendering" `Quick
            test_expr_operator_rendering;
          Alcotest.test_case "case expression rendering" `Quick
            test_case_expression_rendering;
          Alcotest.test_case "schema DDL quotes default literal" `Quick
            test_schema_ddl_quotes_default_literal;
          Alcotest.test_case "schema reference action normalization" `Quick
            test_schema_reference_action_normalization;
        ] );
    ]
end
