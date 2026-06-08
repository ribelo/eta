(** P1 Turso fairness probe — OCaml bindings for C stubs. *)

type db_handle = nativeint

external open_memory : unit -> db_handle = "eta_turso_p1_open_memory"
(** Opens an in-memory Turso database. *)

external exec_sql : db_handle -> string -> unit = "eta_turso_p1_exec_sql"
(** Executes a SQL statement. *)

external run_long_query : db_handle -> string -> float * float * bool * bool
  = "eta_turso_p1_run_long_query"
(** Runs a long query in a blocking section.
    Returns (start_us, end_us, completed, interrupted). *)

external interrupt : db_handle -> unit = "eta_turso_p1_interrupt"
(** Interrupts a running query. *)

external check_select1 : db_handle -> bool = "eta_turso_p1_check_select1"
(** Checks if database is usable by running SELECT 1. *)

external close_db : db_handle -> unit = "eta_turso_p1_close_db"
(** Closes the database. *)

external monotonic_us : unit -> float = "eta_turso_p1_monotonic_us"
(** Returns monotonic time in microseconds. *)
