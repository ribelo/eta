(** P6 DuckDB bulk load probe — OCaml bindings for C stubs. *)

type db_handle = nativeint
type conn_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_p6_open_memory"
(** Opens an in-memory DuckDB database. *)

external connect : db_handle -> conn_handle = "eta_duckdb_p6_connect"
(** Creates a connection from a database handle. *)

external exec_sql : conn_handle -> string -> unit = "eta_duckdb_p6_exec_sql"
(** Executes a SQL statement. *)

external per_row_insert : conn_handle -> int -> float * int
  = "eta_duckdb_p6_per_row_insert"
(** Strategy A: Per-row INSERT.
    Returns (wall_us, rows_inserted). *)

external batched_insert : conn_handle -> int -> float * int
  = "eta_duckdb_p6_batched_insert"
(** Strategy B: Batched VALUES INSERT.
    Returns (wall_us, rows_inserted). *)

external appender_insert : conn_handle -> int -> float * int
  = "eta_duckdb_p6_appender_insert"
(** Strategy C: Appender API.
    Returns (wall_us, rows_inserted). *)

external count_rows : conn_handle -> int = "eta_duckdb_p6_count_rows"
(** Returns the count of rows in bulk_test table. *)

external close_db : db_handle -> unit = "eta_duckdb_p6_close_db"
(** Closes the database. *)

external disconnect : conn_handle -> unit = "eta_duckdb_p6_disconnect"
(** Disconnects the connection. *)

external monotonic_us : unit -> float = "eta_duckdb_p6_monotonic_us"
(** Returns monotonic time in microseconds. *)
