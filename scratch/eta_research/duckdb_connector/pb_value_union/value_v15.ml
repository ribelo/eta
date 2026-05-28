(* 15-case Value.t in separate module — prevents cross-module inlining *)

type t =
  | Null
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bool of bool
  | Bytes of bytes
  | Decimal of { value : int64; scale : int }
  | Timestamp of int64
  | Date of int
  | Uuid of bytes
  | List of t list
  | Struct of (string * t) list
  | Enum of int * string
  | Interval of { months : int; days : int; microseconds : int64 }

(* Function returning Value.t — alternating constructors (same 7 as V7) *)
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
  | Decimal { value; scale } -> Int64.to_int value / scale
  | Timestamp us -> Int64.to_int us
  | Date d -> d
  | Uuid b -> Bytes.length b
  | List l -> List.length l
  | Struct fields -> List.length fields
  | Enum (i, _) -> i
  | Interval { microseconds; _ } -> Int64.to_int microseconds
[@@no_inline]
