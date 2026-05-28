(** P2 DuckDB cancellation probe — OCaml bindings for C stubs. *)

type db_handle = nativeint
type conn_handle = nativeint
type bg_query_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_p2_open_memory"
(** Opens an in-memory DuckDB database. *)

external connect : db_handle -> conn_handle = "eta_duckdb_p2_connect"
(** Creates a connection from a database handle. *)

external exec_sql : conn_handle -> string -> unit = "eta_duckdb_p2_exec_sql"
(** Executes a SQL statement. *)

external run_with_interrupt : conn_handle -> string -> int -> float * float * bool * bool
  = "eta_duckdb_p2_run_with_interrupt"
(** Runs a query with interrupt after delay_ms (currently unused, for future).
    Returns (start_us, end_us, completed, interrupted). *)

external start_background : conn_handle -> string -> bg_query_handle
  = "eta_duckdb_p2_start_background"
(** Starts a query in a background thread. Returns handle. *)

external interrupt_background : conn_handle -> bg_query_handle -> float * float * bool * bool
  = "eta_duckdb_p2_interrupt_background"
(** Interrupts a background query and waits for it to finish.
    Returns (start_us, end_us, completed, interrupted). *)

external interrupt : conn_handle -> unit = "eta_duckdb_p2_interrupt"
(** Interrupts a running query on the connection. *)

external check_select1 : conn_handle -> bool = "eta_duckdb_p2_check_select1"
(** Checks if connection is usable by running SELECT 1. *)

external close_db : db_handle -> unit = "eta_duckdb_p2_close_db"
(** Closes the database. *)

external disconnect : conn_handle -> unit = "eta_duckdb_p2_disconnect"
(** Disconnects the connection. *)

external monotonic_us : unit -> float = "eta_duckdb_p2_monotonic_us"
(** Returns monotonic time in microseconds. *)
