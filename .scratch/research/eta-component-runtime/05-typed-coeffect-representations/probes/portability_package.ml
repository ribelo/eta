module type S = sig
  val get : int
end

let cross
    (value : (module S) @ nonportable)
    : (module S) @ portable =
  value
