(** P-B pattern match test: does widening Value.t force wider pattern matches?

    The question: if you have code that only handles 7 SQLite types,
    does widening Value.t to 15 cases force you to handle the extra 8?

    Answer: No — OCaml allows wildcard patterns. You can write:
      match value with
      | Int i -> ...
      | String s -> ...
      | _ -> default
    This compiles fine even with 15 constructors.

    But: exhaustiveness checking will warn if you don't handle all cases.
    This is a developer ergonomics issue, not a runtime issue. *)

(* ---- 7-case Value.t ---- *)
module V7 = struct
  type t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes
end

(* ---- 15-case Value.t ---- *)
module V15 = struct
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
end

(* ---- Pattern match with wildcard ---- *)
let extract_v7 (value : V7.t) : int =
  match value with
  | V7.Int i -> i
  | V7.Int64 i -> Int64.to_int i
  | V7.Float f -> int_of_float f
  | V7.String s -> String.length s
  | V7.Bool b -> if b then 1 else 0
  | V7.Bytes b -> Bytes.length b
  | V7.Null -> 0

let extract_v15_wildcard (value : V15.t) : int =
  match value with
  | V15.Int i -> i
  | V15.Int64 i -> Int64.to_int i
  | V15.Float f -> int_of_float f
  | V15.String s -> String.length s
  | V15.Bool b -> if b then 1 else 0
  | V15.Bytes b -> Bytes.length b
  | V15.Null -> 0
  | _ -> 0  (* Wildcard handles all DuckDB-specific types *)

let extract_v15_exhaustive (value : V15.t) : int =
  match value with
  | V15.Int i -> i
  | V15.Int64 i -> Int64.to_int i
  | V15.Float f -> int_of_float f
  | V15.String s -> String.length s
  | V15.Bool b -> if b then 1 else 0
  | V15.Bytes b -> Bytes.length b
  | V15.Null -> 0
  | V15.Decimal { value; scale } -> Int64.to_int value / scale
  | V15.Timestamp us -> Int64.to_int us
  | V15.Date d -> d
  | V15.Uuid b -> Bytes.length b
  | V15.List l -> List.length l
  | V15.Struct fields -> List.length fields
  | V15.Enum (i, _) -> i
  | V15.Interval { microseconds; _ } -> Int64.to_int microseconds

let () =
  Printf.printf "=== P-B Pattern Match Test ===\n\n";

  (* Test values *)
  let v7_int = V7.Int 42 in
  let v15_int = V15.Int 42 in
  let v15_decimal = V15.Decimal { value = 12345L; scale = 2 } in

  Printf.printf "V7 extract: %d\n" (extract_v7 v7_int);
  Printf.printf "V15 wildcard extract: %d\n" (extract_v15_wildcard v15_int);
  Printf.printf "V15 exhaustive extract: %d\n" (extract_v15_exhaustive v15_int);
  Printf.printf "V15 decimal extract: %d\n" (extract_v15_exhaustive v15_decimal);

  Printf.printf "\n=== Analysis ===\n";
  Printf.printf "1. Wildcard pattern: Works fine. Code handles 7 SQLite types, ignores 8 DuckDB types.\n";
  Printf.printf "   No runtime overhead. No compile-time error.\n\n";
  Printf.printf "2. Exhaustive pattern: Must handle all 15 cases.\n";
  Printf.printf   "   This is a developer ergonomics issue, not a runtime issue.\n\n";
  Printf.printf "3. Mixed code: SQLite code uses wildcard, DuckDB code handles all 15.\n";
  Printf.printf "   Both work fine in the same program.\n\n";
  Printf.printf "Conclusion: Widening Value.t does NOT force SQLite code to handle DuckDB types.\n";
  Printf.printf "Wildcard patterns work perfectly.\n"
