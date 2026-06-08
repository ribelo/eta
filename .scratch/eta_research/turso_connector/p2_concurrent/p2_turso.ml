(** P2 Turso concurrent write probe — OCaml bindings for C stubs. *)

type db_handle = nativeint

external open_memory : unit -> db_handle = "eta_turso_p2_open_memory"
(** Opens an in-memory Turso database. *)

external exec_sql : db_handle -> string -> unit = "eta_turso_p2_exec_sql"
(** Executes a SQL statement. *)

external concurrent_insert : db_handle -> int -> int -> int * int * float
  = "eta_turso_p2_concurrent_insert"
(** Inserts rows using BEGIN CONCURRENT.
    Returns (rows_inserted, busy_count, wall_us). *)

external count_rows : db_handle -> int = "eta_turso_p2_count_rows"
(** Returns the count of rows in concurrent_test table. *)

external close_db : db_handle -> unit = "eta_turso_p2_close_db"
(** Closes the database. *)
