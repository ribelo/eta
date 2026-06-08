(** P-B microbench: measure allocation delta of widened Value.t on 1M-row scan.

    Baseline: 7-case Value.t (Null, Int, Int64, Float, String, Bool, Bytes)
    Widened: 15-case Value.t (adds Decimal, Timestamp, Date, Uuid, List, Struct, Enum, Interval)

    Measure: Gc.minor_words, Gc.major_words on 1M-row scan with 7 columns. *)

(* ---- Baseline Value.t (7 cases) ---- *)
module Baseline_value = struct
  type t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes

  let of_int i = Int i
  let of_int64 i = Int64 i
  let of_float f = Float f
  let of_string s = String s
  let of_bool b = Bool b
  let of_bytes b = Bytes b
  let null = Null
end

(* ---- Widened Value.t (15 cases) ---- *)
module Widened_value = struct
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

  let of_int i = Int i
  let of_int64 i = Int64 i
  let of_float f = Float f
  let of_string s = String s
  let of_bool b = Bool b
  let of_bytes b = Bytes b
  let null = Null
end

(* ---- Simulate row extraction ---- *)
(* Each row has 7 columns: int, int64, float, string, bool, bytes, nullable_int *)

let num_rows = 1_000_000

let extract_baseline () =
  let gc_before = Gc.quick_stat () in
  let sum = ref 0 in
  for _ = 1 to num_rows do
    (* Simulate extracting 7 columns *)
    let v1 = Baseline_value.of_int 42 in
    let v2 = Baseline_value.of_int64 1234567890L in
    let v3 = Baseline_value.of_float 3.14 in
    let v4 = Baseline_value.of_string "hello world" in
    let v5 = Baseline_value.of_bool true in
    let v6 = Baseline_value.of_bytes (Bytes.make 16 'x') in
    let v7 = Baseline_value.null in
    (* Pattern match to simulate extraction *)
    (match v1 with
     | Baseline_value.Int i -> sum := !sum + i
     | _ -> ());
    (match v2 with
     | Baseline_value.Int64 i -> sum := !sum + Int64.to_int i
     | _ -> ());
    (match v3 with
     | Baseline_value.Float f -> sum := !sum + int_of_float f
     | _ -> ());
    (match v4 with
     | Baseline_value.String s -> sum := !sum + String.length s
     | _ -> ());
    (match v5 with
     | Baseline_value.Bool b -> sum := !sum + (if b then 1 else 0)
     | _ -> ());
    (match v6 with
     | Baseline_value.Bytes b -> sum := !sum + Bytes.length b
     | _ -> ());
    (match v7 with
     | Baseline_value.Null -> ()
     | _ -> sum := !sum + 1)
  done;
  let gc_after = Gc.quick_stat () in
  (gc_after.minor_words -. gc_before.minor_words,
   gc_after.major_words -. gc_before.major_words,
   !sum)

let extract_widened () =
  let gc_before = Gc.quick_stat () in
  let sum = ref 0 in
  for _ = 1 to num_rows do
    (* Simulate extracting 7 columns with widened type *)
    let v1 = Widened_value.of_int 42 in
    let v2 = Widened_value.of_int64 1234567890L in
    let v3 = Widened_value.of_float 3.14 in
    let v4 = Widened_value.of_string "hello world" in
    let v5 = Widened_value.of_bool true in
    let v6 = Widened_value.of_bytes (Bytes.make 16 'x') in
    let v7 = Widened_value.null in
    (* Pattern match to simulate extraction - same 7 cases *)
    (match v1 with
     | Widened_value.Int i -> sum := !sum + i
     | _ -> ());
    (match v2 with
     | Widened_value.Int64 i -> sum := !sum + Int64.to_int i
     | _ -> ());
    (match v3 with
     | Widened_value.Float f -> sum := !sum + int_of_float f
     | _ -> ());
    (match v4 with
     | Widened_value.String s -> sum := !sum + String.length s
     | _ -> ());
    (match v5 with
     | Widened_value.Bool b -> sum := !sum + (if b then 1 else 0)
     | _ -> ());
    (match v6 with
     | Widened_value.Bytes b -> sum := !sum + Bytes.length b
     | _ -> ());
    (match v7 with
     | Widened_value.Null -> ()
     | _ -> sum := !sum + 1)
  done;
  let gc_after = Gc.quick_stat () in
  (gc_after.minor_words -. gc_before.minor_words,
   gc_after.major_words -. gc_before.major_words,
   !sum)

let () =
  Printf.printf "=== P-B Value.t Allocation Microbench ===\n";
  Printf.printf "Rows: %d, Columns per row: 7\n\n" num_rows;

  (* Warmup *)
  let _ = extract_baseline () in
  let _ = extract_widened () in

  (* Baseline *)
  let (baseline_minor, baseline_major, baseline_sum) = extract_baseline () in
  Printf.printf "Baseline (7-case Value.t):\n";
  Printf.printf "  minor_words: %.0f\n" baseline_minor;
  Printf.printf "  major_words: %.0f\n" baseline_major;
  Printf.printf "  sum: %d\n\n" baseline_sum;

  (* Widened *)
  let (widened_minor, widened_major, widened_sum) = extract_widened () in
  Printf.printf "Widened (15-case Value.t):\n";
  Printf.printf "  minor_words: %.0f\n" widened_minor;
  Printf.printf "  major_words: %.0f\n" widened_major;
  Printf.printf "  sum: %d\n\n" widened_sum;

  (* Delta *)
  let minor_delta = widened_minor -. baseline_minor in
  let major_delta = widened_major -. baseline_major in
  let minor_pct = (minor_delta /. baseline_minor) *. 100.0 in
  Printf.printf "Delta:\n";
  Printf.printf "  minor_words: %.0f (%.2f%%)\n" minor_delta minor_pct;
  Printf.printf "  major_words: %.0f\n" major_delta;

  (* Verdict *)
  Printf.printf "\n=== Verdict ===\n";
  if abs_float minor_pct < 5.0 then
    Printf.printf "PASSED - Widened Value.t adds <5%% allocation overhead\n"
  else
    Printf.printf "FAILED - Widened Value.t adds %.2f%% allocation overhead\n" minor_pct
