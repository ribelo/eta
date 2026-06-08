(* P-E Appender cancellation — OCaml bindings. *)

type db_handle = nativeint
type conn_handle = nativeint
type appender_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_pe_open_memory"
external connect : db_handle -> conn_handle = "eta_duckdb_pe_connect"
external disconnect : conn_handle -> unit = "eta_duckdb_pe_disconnect"
external close_db : db_handle -> unit = "eta_duckdb_pe_close_db"
external exec_sql : conn_handle -> string -> bool = "eta_duckdb_pe_exec_sql"
external appender_create : conn_handle -> string -> appender_handle = "eta_duckdb_pe_appender_create"
external appender_append_int : appender_handle -> int -> unit = "eta_duckdb_pe_appender_append_int"
external appender_end_row : appender_handle -> unit = "eta_duckdb_pe_appender_end_row"
external appender_flush : appender_handle -> unit = "eta_duckdb_pe_appender_flush"
external appender_destroy : appender_handle -> unit = "eta_duckdb_pe_appender_destroy"
external check_connection : conn_handle -> bool = "eta_duckdb_pe_check_connection"
