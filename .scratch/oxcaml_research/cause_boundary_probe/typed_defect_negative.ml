(* Candidate C negative: typed portable error payloads cannot contain closures. *)

type bad_error =
  | Bad of (unit -> string)

type ('err : immutable_data) cause : immutable_data =
  | Fail of 'err

let bad : bad_error cause = Fail (Bad (fun () -> "boom"))
let () = ignore bad

