(** P0 LadybugDB C API bindings — direct FFI stubs for link probe. *)

external lbug_version : unit -> string = "eta_lbug_p0_version"
(** Returns the LadybugDB library version string. *)

external lbug_smoke : unit -> string = "eta_lbug_p0_smoke"
(** Opens in-memory DB, creates node table, inserts, queries count.
    Returns "p0_lbug_smoke=count:N" on success. *)

external lbug_api_survey : unit -> string = "eta_lbug_p0_api_survey"
(** Returns a multi-line string summarizing the LadybugDB C API surface. *)
