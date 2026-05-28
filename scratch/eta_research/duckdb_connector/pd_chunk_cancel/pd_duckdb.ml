(* P-D chunk cancellation — OCaml bindings with per-chunk fetch. *)

type db_handle = nativeint
type conn_handle = nativeint
type chunk_handle = nativeint
type result_handle = nativeint

external open_memory : unit -> db_handle = "eta_duckdb_pd_open_memory"
external connect : db_handle -> conn_handle = "eta_duckdb_pd_connect"
external disconnect : conn_handle -> unit = "eta_duckdb_pd_disconnect"
external close_db : db_handle -> unit = "eta_duckdb_pd_close_db"
external exec_sql : conn_handle -> string -> bool = "eta_duckdb_pd_exec_sql"

(* Prepare and execute, return result handle *)
external query_start : conn_handle -> string -> result_handle = "eta_duckdb_pd_query_start"
(* Fetch one chunk. Returns 0 if done. *)
external fetch_chunk : result_handle -> chunk_handle = "eta_duckdb_pd_fetch_chunk"
(* Get chunk size *)
external chunk_size : chunk_handle -> int = "eta_duckdb_pd_chunk_size"
(* Destroy chunk *)
external destroy_chunk : chunk_handle -> unit = "eta_duckdb_pd_destroy_chunk"
(* Destroy result *)
external destroy_result : result_handle -> unit = "eta_duckdb_pd_destroy_result"
(* Check connection *)
external check_connection : conn_handle -> bool = "eta_duckdb_pd_check_connection"
