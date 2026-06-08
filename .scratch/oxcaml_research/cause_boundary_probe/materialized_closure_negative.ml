(* Candidate B negative: materialized diagnostics must stay pure data. *)

type diagnostic : value mod portable = {
  message : string;
  render : unit -> string;
}

let bad = { message = "boom"; render = (fun () -> "boom") }
let () = ignore bad

