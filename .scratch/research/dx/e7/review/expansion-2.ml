(* Exact generated binding excerpt from the explicit-override snapshot. The
   standard ppxlib warning/Merlin include wrapper is omitted. *)

let pp_err : Format.formatter -> err -> unit =
  fun __eta_fmt__001_ ->
    function
    | `Custom __eta_value__002_ ->
        Format.fprintf __eta_fmt__001_ "custom:%a" pp_string
          __eta_value__002_
