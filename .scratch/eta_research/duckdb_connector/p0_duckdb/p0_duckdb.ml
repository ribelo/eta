(** P0 DuckDB C API bindings — direct FFI stubs for link probe. *)

external duckdb_version : unit -> string = "eta_duckdb_p0_version"
(** Returns the DuckDB library version string. *)

external duckdb_smoke : unit -> string = "eta_duckdb_p0_smoke"
(** Opens in-memory DB, creates table, inserts, queries count.
    Returns "p0_duckdb_smoke=count:N" on success. *)

external duckdb_api_survey : unit -> string = "eta_duckdb_p0_api_survey"
(** Returns a multi-line string summarizing the DuckDB C API surface. *)
