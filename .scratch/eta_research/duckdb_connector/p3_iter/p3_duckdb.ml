(** P3 DuckDB chunk iteration probe — OCaml bindings for C stubs. *)

type db_handle = nativeint
type conn_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_p3_open_memory"
(** Opens an in-memory DuckDB database. *)

external connect : db_handle -> conn_handle = "eta_duckdb_p3_connect"
(** Creates a connection from a database handle. *)

external exec_sql : conn_handle -> string -> unit = "eta_duckdb_p3_exec_sql"
(** Executes a SQL statement. *)

external materialize : conn_handle -> string -> float * int * int * int * int
  = "eta_duckdb_p3_materialize"
(** Strategy A: Full materialization.
    Returns (wall_us, rows, sum, minor_words, major_words). *)

external chunk_iter : conn_handle -> string -> float * int * int * int * int
  = "eta_duckdb_p3_chunk_iter"
(** Strategy B: Chunk iteration.
    Returns (wall_us, rows, sum, minor_words, major_words). *)

external close_db : db_handle -> unit = "eta_duckdb_p3_close_db"
(** Closes the database. *)

external disconnect : conn_handle -> unit = "eta_duckdb_p3_disconnect"
(** Disconnects the connection. *)

external monotonic_us : unit -> float = "eta_duckdb_p3_monotonic_us"
(** Returns monotonic time in microseconds. *)
