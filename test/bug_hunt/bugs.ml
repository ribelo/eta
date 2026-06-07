(* Failing tests that demonstrate concrete bugs in the Eta runtime and the
   eta_sql DSL. Each test carries a comment explaining the correct behavior it
   is checking for. None of these tests "game" the suite: they assert behavior
   that a correct implementation must satisfy. *)

module Q = Eta_sql
module S = Eta_sql.Sqlite

let ( let* ) eff f = Eta.Effect.bind f eff

(* ------------------------------------------------------------------ *)
(* Bug 1: Duration.scale by 1.0 is not the identity at the maximum.    *)
(* ------------------------------------------------------------------ *)

let test_duration_scale_identity_at_max () =
  (* Scaling a duration by the factor 1.0 must be the identity: it cannot
     change the duration at all. [Duration.scale] guards overflow with
     [scaled > float_of_int max_int], but [float_of_int max_int] rounds the
     63-bit max up to 2^62. For [ms max_int] scaled by 1.0 the product equals
     2^62 exactly, so the strict ">" guard does not fire; [int_of_float 2^62]
     then overflows to a negative int and [clamp_nonnegative] collapses it to 0.
     The correct result is [max_int]. *)
  Alcotest.(check int)
    "scale by 1.0 must be the identity"
    max_int
    (Eta.Duration.to_ms (Eta.Duration.scale (Eta.Duration.ms max_int) 1.0))

(* ------------------------------------------------------------------ *)
(* Bug 2: jittered exponential backoff raises once the delay saturates *)
(* ------------------------------------------------------------------ *)

let test_schedule_jittered_exponential_does_not_raise () =
  (* Jittered exponential backoff is the most common retry policy. Exponential
     delays are intentionally clamped to the maximum representable duration via
     [scale_capped]. But [Schedule.jittered] multiplies the inner delay with
     [Duration.scale] (NOT the capped variant). Once the exponential delay
     saturates at [ms max_int] and the jitter factor is > 1.0, [Duration.scale]
     raises [Invalid_argument "Duration.scale"]. Advancing a legal schedule must
     never raise; jitter should clamp like the rest of the schedule machinery. *)
  let sch =
    Eta.Schedule.(
      jittered ~min:1.1 ~max:1.2 (exponential ~factor:2.0 (Eta.Duration.seconds 1)))
  in
  let driver = ref (Eta.Schedule.start ~random:(Eta.Capabilities.random_of_seed 7) sch) in
  (* 80 steps is enough for factor 2.0 over a 1s base to saturate at max_int. *)
  for _ = 1 to 80 do
    match Eta.Schedule.next !driver with
    | Some (_, next_driver) -> driver := next_driver
    | None -> ()
  done;
  Alcotest.(check bool) "advancing the schedule never raised" true true

(* ------------------------------------------------------------------ *)
(* Bug 3: float column DEFAULT loses precision in generated schema SQL *)
(* ------------------------------------------------------------------ *)

module Measures = struct
  module T = Q.Table.Make (struct
    let name = "measures"
  end)

  include T

  let id = column "id" Q.int
  let ratio = column "ratio" Q.float
end

let pp_pool_error ppf = function
  | `Eta_sql err -> Q.pp_error ppf err
  | `Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
  | `Timeout -> Format.pp_print_string ppf "timeout"

let run_effect program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt program with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> Alcotest.failf "%a" (Eta.Cause.pp pp_pool_error) cause

let run_effect_exit program =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  Eta.Runtime.run rt program

let with_pool_effect f =
  let acquire =
    Q.Pool.create ~default_timeout:(Eta.Duration.ms 500) ~max_size:1
      (S.memory_config ())
  in
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire ~release:Q.Pool.shutdown
     |> Eta.Effect.bind f)

let with_pool f = with_pool_effect f |> run_effect
let with_pool_exit f = with_pool_effect f |> run_effect_exit

let test_schema_float_default_round_trips () =
  (* The full-precision double for pi needs 17 significant digits to round-trip.
     The schema generator renders a column DEFAULT via [value_to_sql_literal],
     which uses [string_of_float] (~12 significant digits). The emitted
     "DEFAULT 3.14159265359" loses precision, so a row that relies on the
     default stores a different value than the one the program declared. A
     declared float default must round-trip exactly. *)
  let pi = 3.141592653589793 in
  let stored =
    with_pool @@ fun pool ->
    let* () =
      Q.Pool.Typed.run_schema pool
        (Q.Eta_schema.compile
           Q.Eta_schema.(
             create_table Measures.table
               [
                 column ~primary_key:true Measures.id;
                 column ~not_null:true ~default:pi Measures.ratio;
               ]))
    in
    let* _ =
      Q.Pool.Typed.execute_compiled pool
        Q.Insert.(into Measures.table |> value Measures.id 1 |> compile)
    in
    let* rows =
      Q.Pool.Typed.select pool
        (Q.Select.compile
           Q.Select.(
             from Measures.table (Q.Projection.one Measures.ratio)
             |> where (Q.Expr.eq Measures.id 1)))
    in
    match rows with
    | [ ratio ] -> Eta.Effect.pure ratio
    | _ ->
        Eta.Effect.fail
          (`Eta_sql
            (Q.Decode_error
               { operation = "test"; message = "expected exactly one row" }))
  in
  Alcotest.(check (float 0.0)) "declared float default round-trips" pi stored

(* ------------------------------------------------------------------ *)
(* Bug 4: SQLite decodes SQL NULL as a fabricated 0 through a          *)
(*        non-nullable typed column, unlike the DuckDB/Turso backends. *)
(* ------------------------------------------------------------------ *)

module Nullables = struct
  module T = Q.Table.Make (struct
    let name = "nullables"
  end)

  include T

  let id = column "id" Q.int

  (* [n] is a non-nullable [int] typ, but the table column itself permits NULL
     (no NOT NULL constraint, no default). *)
  let n = column "n" Q.int
end

let test_sqlite_null_decoded_as_nonnull_int () =
  (* The typed DSL ships [nullable] and [column_is_null] precisely so that SQL
     NULL is explicit in the types: a value typed as a non-nullable [int] must
     never come from a NULL cell. The DuckDB and Turso backends enforce this by
     raising a decode failure when a NULL reaches a non-nullable decoder. The
     SQLite backend instead binds [int]'s decoder straight to
     [Sqlite.column_int] (which calls sqlite3_column_int64 with no NULL check),
     so a NULL integer is silently decoded as 0. That fabricates data and makes
     the same typed program behave differently across Eta SQL backends.

     Correct behavior: decoding a NULL through a non-nullable column must not
     yield 0 — it must surface an error (as DuckDB/Turso do). *)
  let result =
    with_pool_exit @@ fun pool ->
    let* () =
      Q.Pool.Typed.run_schema pool
        (Q.Eta_schema.compile
           Q.Eta_schema.(
             create_table Nullables.table
               [ column ~primary_key:true Nullables.id; column Nullables.n ]))
    in
    (* Insert a row whose [n] is SQL NULL: the column is omitted and has no
       default, so SQLite stores NULL. *)
    let* _ =
      Q.Pool.Typed.execute_compiled pool
        Q.Insert.(into Nullables.table |> value Nullables.id 1 |> compile)
    in
    Q.Pool.Typed.select pool
      (Q.Select.compile
         Q.Select.(
           from Nullables.table (Q.Projection.one Nullables.n)
           |> where (Q.Expr.eq Nullables.id 1)))
  in
  match result with
  | Eta.Exit.Error (Eta.Cause.Fail (`Eta_sql (Q.Decode_error _))) ->
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected typed Decode_error, got %a"
        (Eta.Cause.pp pp_pool_error) cause
  | Eta.Exit.Ok [ 0 ] ->
      Alcotest.failf
        "decoded SQL NULL as non-nullable int and silently produced 0"
  | Eta.Exit.Ok rows ->
      Alcotest.failf "expected a decode error for NULL, got %d row(s)"
        (List.length rows)

(* ------------------------------------------------------------------ *)
(* Bug 5: DuckDB cannot read a TIMESTAMP/DATE/DECIMAL/UUID/ENUM column  *)
(*        once any column in the result is a LIST.                     *)
(* ------------------------------------------------------------------ *)

module D = Eta_duckdb

let with_duckdb f =
  match D.available () with
  | Error _ -> ()
  | Ok () -> (
      match D.Database.open_memory () with
      | Error err -> Alcotest.failf "open_memory: %a" D.pp_error err
      | Ok db ->
          Fun.protect
            ~finally:(fun () -> ignore (D.Database.close db))
            (fun () ->
              match D.Connection.connect db with
              | Error err -> Alcotest.failf "connect: %a" D.pp_error err
              | Ok conn ->
                  Fun.protect
                    ~finally:(fun () -> ignore (D.Connection.close conn))
                    (fun () -> f conn)))

let test_duckdb_list_alongside_timestamp_column () =
  (* DuckDB results materialize column-by-column. The non-LIST path
     (value_from_result) decodes DATE/TIME/TIMESTAMP/DECIMAL/UUID/ENUM via its
     default branch. But as soon as ANY result column is a LIST, the whole
     result is materialized through the chunk path (value_from_vector), which
     only handles BOOLEAN/INT*/FLOAT/DOUBLE/VARCHAR/BLOB/LIST and calls
     caml_failwith("duckdb unsupported vector result type") for TIMESTAMP.
     Therefore a query selecting a LIST column next to a TIMESTAMP column fails
     even though each column type is individually supported.

     Correct behavior: both queries below must succeed. The second one only
     differs from a working query by the presence of an unrelated LIST column. *)
  with_duckdb @@ fun conn ->
  (* A TIMESTAMP column on its own decodes fine (non-LIST path). *)
  (match
     D.Connection.query conn "SELECT TIMESTAMP '2020-01-01 00:00:00' AS ts" []
   with
   | Ok _ -> ()
   | Error err ->
       Alcotest.failf "a TIMESTAMP column alone should decode: %a" D.pp_error err);
  (* Adding an unrelated LIST column must not make the TIMESTAMP unreadable. *)
  match
    D.Connection.query conn
      "SELECT [1, 2, 3] AS lst, TIMESTAMP '2020-01-01 00:00:00' AS ts" []
  with
  | Ok _ -> ()
  | Error err ->
      Alcotest.failf
        "LIST + TIMESTAMP must decode, but the chunk path rejected it: %a"
        D.pp_error err

let test_duckdb_execute_reports_changed_rows () =
  (* Connection.execute is documented to return the changed-row count. The stub
     reads [result.deprecated_rows_changed], which modern DuckDB does not
     populate for prepared-statement execution (the correct accessor is
     [duckdb_rows_changed]), so every INSERT/UPDATE/DELETE reports 0 changed
     rows. Inserting three rows must report 3. *)
  with_duckdb @@ fun conn ->
  (match D.Connection.exec_script conn "CREATE TABLE chg (id INTEGER)" with
   | Ok () -> ()
   | Error err -> Alcotest.failf "create table: %a" D.pp_error err);
  match D.Connection.execute conn "INSERT INTO chg VALUES (1), (2), (3)" [] with
  | Ok 3 -> ()
  | Ok n -> Alcotest.failf "expected 3 changed rows, got %d" n
  | Error err -> Alcotest.failf "execute: %a" D.pp_error err

let test_duckdb_uuid_decodes_to_text () =
  (* UUID, TIMESTAMPTZ and ENUM values are materialized via the deprecated
     value_varchar accessor in value_from_result's default branch. In modern
     DuckDB that accessor returns NULL for these types, and the stub maps a NULL
     varchar to "" — so a non-NULL UUID/ENUM/TIMESTAMPTZ silently decodes as the
     empty string (DATE/TIME/TIMESTAMP/DECIMAL/INTERVAL still work, which is why
     this slips through). A non-NULL UUID must decode to its textual form. *)
  with_duckdb @@ fun conn ->
  match
    D.Connection.query conn
      "SELECT '12345678-1234-5678-1234-567812345678'::UUID AS u" []
  with
  | Ok [ [ (_, v) ] ] ->
      Alcotest.(check string)
        "uuid decodes to text" "12345678-1234-5678-1234-567812345678"
        (D.Value.to_string v)
  | Ok _ -> Alcotest.fail "expected exactly one row/column"
  | Error err -> Alcotest.failf "query: %a" D.pp_error err

(* ------------------------------------------------------------------ *)
(* Bug 6: Turso exec_script runs only the FIRST statement of a script. *)
(* ------------------------------------------------------------------ *)

module Tu = Eta_turso

let test_turso_exec_script_runs_every_statement () =
  (* "exec_script" is named (and used, e.g. by run_schema) like a runner for a
     full multi-statement SQL script; the SQLite backend's exec_script uses
     sqlite3_exec and runs every statement. Turso's exec_script instead calls
     [execute], which prepares with sqlite3_prepare_v2 and a NULL tail and steps
     once, so only the FIRST statement of a multi-statement script runs — the
     rest are silently dropped. Both tables below must exist afterwards. *)
  match Tu.available () with
  | Error _ -> () (* libturso_sqlite3 not present: skip rather than false-fail *)
  | Ok () -> (
      let config = { (Tu.default_config ":memory:") with journal_mode = Tu.Wal } in
      match Tu.open_ config with
      | Error err -> Alcotest.failf "turso open: %a" Tu.pp_error err
      | Ok db ->
          Fun.protect ~finally:(fun () -> ignore (Tu.close db)) @@ fun () ->
          (match
             Tu.exec_script db
               "CREATE TABLE a (id INTEGER); CREATE TABLE b (id INTEGER);"
           with
           | Ok () -> ()
           | Error err -> Alcotest.failf "exec_script: %a" Tu.pp_error err);
          (* The second statement must have created table [b]. *)
          (match Tu.query db "SELECT count(*) FROM b" [] with
           | Ok _ -> ()
           | Error err ->
               Alcotest.failf
                 "second statement of the script never ran (table b missing): %a"
                 Tu.pp_error err))

(* ------------------------------------------------------------------ *)
(* Bug 9: LadybugDB LIST values decode as String "" instead of a list. *)
(* ------------------------------------------------------------------ *)

module Lb = Eta_ladybug

let test_ladybug_list_decodes_as_list () =
  (* LadybugDB returns query results over the Arrow C data interface.
     [arrow_value] in the stub handles scalars ("b"/"l"/"g"/"u") and structs
     ("+s") but has NO case for the Arrow list formats ("+l"/"+L"); it falls
     through to a default that returns [String ""]. So every Cypher LIST value
     (e.g. [1,2,3]) silently decodes as the empty string instead of
     [Value.List]. A list must decode to [Value.List] with its elements. *)
  match Lb.available () with
  | Error _ -> () (* liblbug not present: skip rather than false-fail *)
  | Ok () -> (
      match Lb.Database.open_memory () with
      | Error e -> Alcotest.failf "ladybug open: %s" (Lb.show_error e)
      | Ok db ->
          Fun.protect ~finally:(fun () -> ignore (Lb.Database.close db)) @@ fun () ->
          match Lb.Connection.connect db with
          | Error e -> Alcotest.failf "ladybug connect: %s" (Lb.show_error e)
          | Ok conn ->
              Fun.protect ~finally:(fun () -> ignore (Lb.Connection.close conn))
              @@ fun () ->
              let q =
                Lb.Query.raw ~cypher:"RETURN [1, 2, 3] AS v"
                  ~decode:(Lb.Decode.value "v") ()
              in
              (match Lb.Connection.query conn q with
               | Ok [ Lb.Value.List [ Lb.Value.Int 1L; Lb.Value.Int 2L; Lb.Value.Int 3L ] ]
                 -> ()
               | Ok [ Lb.Value.String s ] ->
                   Alcotest.failf
                     "Cypher LIST decoded as String %S instead of Value.List" s
               | Ok [ _ ] ->
                   Alcotest.fail "Cypher LIST decoded as the wrong constructor"
               | Ok _ -> Alcotest.fail "expected exactly one row"
               | Error e -> Alcotest.failf "ladybug query: %s" (Lb.show_error e)))

(* ------------------------------------------------------------------ *)
(* Bug 10: LadybugDB Rel values decode as Node instead of Rel.         *)
(* ------------------------------------------------------------------ *)

let test_ladybug_rel_decodes_as_rel () =
  (* LadybugDB relationships are returned as Arrow structs with _LABEL, _ID,
     _SRC, and _DST children. [arrow_value] checks for a _LABEL child to
     decide "this is a node", but relationships ALSO have _LABEL. There is no
     check for _SRC/_DST (which only rels have), so every relationship
     silently decodes as [Value.Node] instead of [Value.Rel]. *)
  match Lb.available () with
  | Error _ -> ()
  | Ok () -> (
      match Lb.Database.open_memory () with
      | Error e -> Alcotest.failf "ladybug open: %s" (Lb.show_error e)
      | Ok db ->
          Fun.protect ~finally:(fun () -> ignore (Lb.Database.close db)) @@ fun () ->
          match Lb.Connection.connect db with
          | Error e -> Alcotest.failf "ladybug connect: %s" (Lb.show_error e)
          | Ok conn ->
              Fun.protect ~finally:(fun () -> ignore (Lb.Connection.close conn))
              @@ fun () ->
              ignore (Lb.Connection.exec conn "CREATE NODE TABLE Person(name STRING, age INT64, PRIMARY KEY(name))");
              ignore (Lb.Connection.exec conn "CREATE REL TABLE Knows(FROM Person TO Person, since INT64, MANY_MANY)");
              ignore (Lb.Connection.exec conn "CREATE (:Person {name:'Ada', age:36})");
              ignore (Lb.Connection.exec conn "CREATE (:Person {name:'Bob', age:30})");
              ignore (Lb.Connection.exec conn "MATCH (a:Person {name:'Ada'}), (b:Person {name:'Bob'}) CREATE (a)-[:Knows {since:2020}]->(b)");
              let q =
                Lb.Query.raw ~cypher:"MATCH ()-[r:Knows]->() RETURN r AS v"
                  ~decode:(Lb.Decode.value "v") ()
              in
              (match Lb.Connection.query conn q with
               | Ok [ Lb.Value.Rel r ] ->
                   Alcotest.(check (option string))
                     "rel label" (Some "Knows") r.label
               | Ok [ Lb.Value.Node n ] ->
                   Alcotest.failf
                     "relationship decoded as Node(labels=%s) instead of Rel"
                     (String.concat "," n.labels)
               | Ok [ _ ] ->
                   Alcotest.fail "relationship decoded as wrong constructor"
               | Ok _ -> Alcotest.fail "expected exactly one row"
               | Error e -> Alcotest.failf "ladybug query: %s" (Lb.show_error e)))

(* ------------------------------------------------------------------ *)
(* Bug 11: LadybugDB Path values decode as Map instead of Path.        *)
(* ------------------------------------------------------------------ *)

let test_ladybug_path_decodes_as_path () =
  (* LadybugDB paths are returned as Arrow structs with _NODES and _RELS
     children. The stub has no [arrow_path] function, so paths fall through to
     [arrow_struct_map] and decode as [Value.Map] instead of [Value.Path]. *)
  match Lb.available () with
  | Error _ -> ()
  | Ok () -> (
      match Lb.Database.open_memory () with
      | Error e -> Alcotest.failf "ladybug open: %s" (Lb.show_error e)
      | Ok db ->
          Fun.protect ~finally:(fun () -> ignore (Lb.Database.close db)) @@ fun () ->
          match Lb.Connection.connect db with
          | Error e -> Alcotest.failf "ladybug connect: %s" (Lb.show_error e)
          | Ok conn ->
              Fun.protect ~finally:(fun () -> ignore (Lb.Connection.close conn))
              @@ fun () ->
              ignore (Lb.Connection.exec conn "CREATE NODE TABLE Person(name STRING, age INT64, PRIMARY KEY(name))");
              ignore (Lb.Connection.exec conn "CREATE REL TABLE Knows(FROM Person TO Person, since INT64, MANY_MANY)");
              ignore (Lb.Connection.exec conn "CREATE (:Person {name:'Ada', age:36})");
              ignore (Lb.Connection.exec conn "CREATE (:Person {name:'Bob', age:30})");
              ignore (Lb.Connection.exec conn "MATCH (a:Person {name:'Ada'}), (b:Person {name:'Bob'}) CREATE (a)-[:Knows {since:2020}]->(b)");
              let q =
                Lb.Query.raw ~cypher:"MATCH p=(:Person)-[:Knows]->(:Person) RETURN p AS v"
                  ~decode:(Lb.Decode.value "v") ()
              in
              (match Lb.Connection.query conn q with
               | Ok [ Lb.Value.Path _ ] -> ()
               | Ok [ Lb.Value.Map _ ] ->
                   Alcotest.fail "path decoded as Map instead of Path"
               | Ok [ _ ] ->
                   Alcotest.fail "path decoded as wrong constructor"
               | Ok _ -> Alcotest.fail "expected exactly one row"
               | Error e -> Alcotest.failf "ladybug query: %s" (Lb.show_error e)))

(* ------------------------------------------------------------------ *)
(* Bug 12: LadybugDB timestamp/date decode as empty String "".         *)
(* ------------------------------------------------------------------ *)

let test_ladybug_timestamp_not_empty_string () =
  (* LadybugDB timestamps and dates are returned over Arrow with format
     strings like [ttn] (timestamp[ns]) and [tdD] (date32). [arrow_value]
     handles b/l/g/u/+l/+L/+s but has NO case for temporal types; they fall
     through to a default returning [String ""]. A timestamp must not silently
     decode as the empty string (it should become [Int] or a non-empty
     [String] at minimum). *)
  match Lb.available () with
  | Error _ -> ()
  | Ok () -> (
      match Lb.Database.open_memory () with
      | Error e -> Alcotest.failf "ladybug open: %s" (Lb.show_error e)
      | Ok db ->
          Fun.protect ~finally:(fun () -> ignore (Lb.Database.close db)) @@ fun () ->
          match Lb.Connection.connect db with
          | Error e -> Alcotest.failf "ladybug connect: %s" (Lb.show_error e)
          | Ok conn ->
              Fun.protect ~finally:(fun () -> ignore (Lb.Connection.close conn))
              @@ fun () ->
              let q =
                Lb.Query.raw ~cypher:"RETURN timestamp('2020-01-01') AS v"
                  ~decode:(Lb.Decode.value "v") ()
              in
              (match Lb.Connection.query conn q with
               | Ok [ Lb.Value.String "" ] ->
                   Alcotest.fail "timestamp decoded as empty string"
               | Ok [ Lb.Value.Int _ ] -> ()
               | Ok [ Lb.Value.String _ ] -> ()
               | Ok [ _ ] ->
                   Alcotest.fail "timestamp decoded as unexpected constructor"
               | Ok _ -> Alcotest.fail "expected exactly one row"
               | Error e -> Alcotest.failf "ladybug query: %s" (Lb.show_error e)))
