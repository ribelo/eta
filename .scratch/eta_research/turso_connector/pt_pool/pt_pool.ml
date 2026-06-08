type db = nativeint

external open_file : string -> db = "eta_turso_pool_open"
external close_db : db -> unit = "eta_turso_pool_close"
external exec_sql : db -> string -> bool = "eta_turso_pool_exec"

