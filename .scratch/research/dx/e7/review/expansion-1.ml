(* Exact generated binding excerpt from the mixed expansion snapshot. The
   standard ppxlib warning/Merlin include wrapper is omitted. *)

let pp_err : Format.formatter -> err -> unit =
  fun __eta_fmt__001_ ->
    function
    | `Not_found __eta_value__002_ ->
        Format.fprintf __eta_fmt__001_ "not_found:%s" __eta_value__002_
    | `Db __eta_value__003_ ->
        Format.fprintf __eta_fmt__001_ "db:%d" __eta_value__003_
    | `Unavailable ->
        Format.pp_print_string __eta_fmt__001_ "unavailable"
