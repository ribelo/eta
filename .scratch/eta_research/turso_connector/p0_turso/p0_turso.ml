(** P0 Turso C API bindings — direct FFI stubs for link probe. *)

external turso_version : unit -> string = "eta_turso_p0_version"
(** Returns the Turso/SQLite library version string. *)

external turso_smoke : unit -> string = "eta_turso_p0_smoke"
(** Opens in-memory DB, creates table, inserts, queries count.
    Returns "p0_turso_smoke=count:N" on success. *)

external turso_api_survey : unit -> string = "eta_turso_p0_api_survey"
(** Returns a multi-line string summarizing the Turso C API surface. *)
