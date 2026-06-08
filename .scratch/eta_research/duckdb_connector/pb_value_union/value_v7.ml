(* 7-case Value.t in separate module — prevents cross-module inlining *)

type t =
  | Null
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bool of bool
  | Bytes of bytes

(* Function returning Value.t — alternating constructors *)
let get_value idx =
  match idx mod 7 with
  | 0 -> Int idx
  | 1 -> Int64 (Int64.of_int idx)
  | 2 -> Float (float_of_int idx)
  | 3 -> String "hello"
  | 4 -> Bool true
  | 5 -> Bytes (Bytes.make 16 'x')
  | _ -> Null
[@@no_inline]

(* Pattern match on Value.t — simulates typed builder extract *)
let extract_int = function
  | Int i -> i
  | Int64 i -> Int64.to_int i
  | Float f -> int_of_float f
  | String s -> String.length s
  | Bool b -> if b then 1 else 0
  | Bytes b -> Bytes.length b
  | Null -> 0
[@@no_inline]
