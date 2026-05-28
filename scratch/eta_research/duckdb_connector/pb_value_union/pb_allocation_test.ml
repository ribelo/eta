(** P-B allocation test: does widening Value.t cost real allocations?

    Test order: V15 first, then V7. *)

let num_rows = 1_000_000
let num_cols = 7

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

let () =
  Printf.printf "=== P-B Value.t Allocation Test ===\n";
  Printf.printf "Constructing %d values (%d rows × %d cols)\n\n" (num_rows * num_cols) num_rows num_cols;
  Printf.printf "Order: V15 first, then V7\n\n";

  (* Test 1: Construct V15 values FIRST *)
  let gc_before = Gc.quick_stat () in
  let count = ref 0 in
  for i = 1 to num_rows do
    let _v1 : V15.t = V15.Int i in
    let _v2 : V15.t = V15.Int64 (Int64.of_int i) in
    let _v3 : V15.t = V15.Float (float_of_int i) in
    let _v4 : V15.t = V15.String "hello" in
    let _v5 : V15.t = V15.Bool true in
    let _v6 : V15.t = V15.Bytes (Bytes.make 16 'x') in
    let _v7 : V15.t = V15.Null in
    count := !count + 7
  done;
  let gc_after = Gc.quick_stat () in
  let v15_minor = gc_after.minor_words -. gc_before.minor_words in
  let v15_major = gc_after.major_words -. gc_before.major_words in
  Printf.printf "V15 (15 constructors, run first):\n";
  Printf.printf "  values constructed: %d\n" !count;
  Printf.printf "  minor_words: %.0f\n" v15_minor;
  Printf.printf "  major_words: %.0f\n" v15_major;
  Printf.printf "  per_value: %.2f minor_words\n\n" (v15_minor /. float_of_int !count);

  (* Test 2: Construct V7 values SECOND *)
  let gc_before = Gc.quick_stat () in
  let count = ref 0 in
  for i = 1 to num_rows do
    let _v1 : V7.t = V7.Int i in
    let _v2 : V7.t = V7.Int64 (Int64.of_int i) in
    let _v3 : V7.t = V7.Float (float_of_int i) in
    let _v4 : V7.t = V7.String "hello" in
    let _v5 : V7.t = V7.Bool true in
    let _v6 : V7.t = V7.Bytes (Bytes.make 16 'x') in
    let _v7 : V7.t = V7.Null in
    count := !count + 7
  done;
  let gc_after = Gc.quick_stat () in
  let v7_minor = gc_after.minor_words -. gc_before.minor_words in
  let v7_major = gc_after.major_words -. gc_before.major_words in
  Printf.printf "V7 (7 constructors, run second):\n";
  Printf.printf "  values constructed: %d\n" !count;
  Printf.printf "  minor_words: %.0f\n" v7_minor;
  Printf.printf "  major_words: %.0f\n" v7_major;
  Printf.printf "  per_value: %.2f minor_words\n\n" (v7_minor /. float_of_int !count);

  (* Delta *)
  let minor_delta = v15_minor -. v7_minor in
  let minor_pct = if v7_minor > 0.0 then (minor_delta /. v7_minor) *. 100.0 else 0.0 in
  Printf.printf "Delta (V15 - V7):\n";
  Printf.printf "  minor_words: %.0f (%.2f%%)\n" minor_delta minor_pct;

  Printf.printf "\n=== Analysis ===\n";
  if v15_minor < v7_minor then begin
    Printf.printf "V15 allocated LESS than V7 despite running first.\n";
    Printf.printf "This suggests the delta is a GC artifact, not real overhead.\n"
  end else if abs_float minor_pct < 5.0 then begin
    Printf.printf "Delta is <5%% — within noise.\n";
    Printf.printf "Widening Value.t does NOT add meaningful allocation overhead.\n"
  end else begin
    Printf.printf "Delta is %.2f%% — real overhead detected.\n" minor_pct;
    Printf.printf "Widening Value.t adds allocation overhead.\n"
  end
