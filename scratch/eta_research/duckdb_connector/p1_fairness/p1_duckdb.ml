(** P1 DuckDB fairness probe — OCaml bindings for C stubs. *)

type db_handle = nativeint
type conn_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_p1_open_memory"
(** Opens an in-memory DuckDB database. *)

external connect : db_handle -> conn_handle = "eta_duckdb_p1_connect"
(** Creates a connection from a database handle. *)

external exec_sql : conn_handle -> string -> unit = "eta_duckdb_p1_exec_sql"
(** Executes a SQL statement. *)

external run_long_query : conn_handle -> string -> float * float * bool * bool
  = "eta_duckdb_p1_run_long_query"
(** Runs a long query in a blocking section.
    Returns (start_us, end_us, completed, interrupted). *)

external interrupt : conn_handle -> unit = "eta_duckdb_p1_interrupt"
(** Interrupts a running query on the connection. *)

external check_select1 : conn_handle -> bool = "eta_duckdb_p1_check_select1"
(** Checks if connection is usable by running SELECT 1. *)

external close_db : db_handle -> unit = "eta_duckdb_p1_close_db"
(** Closes the database. *)

external disconnect : conn_handle -> unit = "eta_duckdb_p1_disconnect"
(** Disconnects the connection. *)

external monotonic_us : unit -> float = "eta_duckdb_p1_monotonic_us"
(** Returns monotonic time in microseconds. *)
