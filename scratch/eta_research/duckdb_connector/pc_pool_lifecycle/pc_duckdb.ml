(** P-C pool lifecycle — OCaml bindings. *)

type db_handle = nativeint
type conn_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_pc_open_memory"
external connect : db_handle -> conn_handle = "eta_duckdb_pc_connect"
external disconnect : conn_handle -> unit = "eta_duckdb_pc_disconnect"
external close_db : db_handle -> unit = "eta_duckdb_pc_close_db"
external exec_sql : conn_handle -> string -> bool = "eta_duckdb_pc_exec_sql"
external is_db_closed : db_handle -> bool = "eta_duckdb_pc_is_db_closed"
external try_connect_to_closed : db_handle -> bool = "eta_duckdb_pc_try_connect_to_closed"
