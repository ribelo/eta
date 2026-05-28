type db = nativeint
type conn = nativeint

external open_memory : unit -> db = "eta_lbug_p2_open_memory"
external connect : db -> conn = "eta_lbug_p2_connect"
external exec : conn -> string -> unit = "eta_lbug_p2_exec"
external query : conn -> string -> string = "eta_lbug_p2_query_blocking"
external interrupt : conn -> unit = "eta_lbug_p2_interrupt"
external check_return1 : conn -> bool = "eta_lbug_p2_check_return1"
external close_conn : conn -> unit = "eta_lbug_p2_close_conn"
external close_db : db -> unit = "eta_lbug_p2_close_db"
external monotonic_us : unit -> float = "eta_lbug_p2_monotonic_us"
