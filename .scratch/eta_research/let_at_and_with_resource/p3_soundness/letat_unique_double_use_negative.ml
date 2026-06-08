open Eta

module Local_resource : sig
  type borrow

  val consume : borrow @ local unique -> (unit, 'err) Effect.t
  val with_borrow : (borrow @ local unique -> ('a, 'err) Effect.t) -> ('a, 'err) Effect.t
end = struct
  type borrow = { id : int }

  let consume (_borrow @ local unique) = Effect.unit
  let with_borrow f =
    let local_ borrow = { id = 1 } in
    f borrow
end

let bad_double_use () =
  let ( let@ ) f k = f k in
  let open Syntax in
  let@ borrow = Local_resource.with_borrow in
  let* () = Local_resource.consume borrow in
  Local_resource.consume borrow
