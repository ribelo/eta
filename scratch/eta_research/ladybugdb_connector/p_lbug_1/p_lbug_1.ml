(** P-Lbug-1 Arrow C-data probe bindings. *)

external arrow_node_probe : unit -> string = "eta_lbug_p1_arrow_node_probe"

type node = {
  label : string;
  internal_offset : int64;
  internal_table : int64;
  id : int64;
  name : string;
  age : int64;
  active : bool;
}

external decode_node_record_raw
  :  unit -> string * int64 * int64 * int64 * string * int64 * bool
  = "eta_lbug_p1_decode_node_record"

let decode_node_record () =
  let label, internal_offset, internal_table, id, name, age, active =
    decode_node_record_raw ()
  in
  { label; internal_offset; internal_table; id; name; age; active }
