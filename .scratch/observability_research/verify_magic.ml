(* Verify what OCaml's compile-time magic identifiers actually do.
   Run this and read the output. *)

(* __POS__ : string * int * int * int — (file, line, col_start, col_end) *)
let pos_at_top = __POS__

(* __FUNCTION__ : string — the enclosing function name, OCaml 5.1+. *)
let function_at_top =
  let _ = () in
  __FUNCTION__

(* What does __FUNCTION__ give in nested contexts? *)
let outer_fn () =
  let inner_lambda = fun () -> __FUNCTION__ in
  let inner_fn = fun () -> __FUNCTION__ in
  let result_let_binding =
    let inner_let = __FUNCTION__ in
    inner_let
  in
  (inner_lambda (), inner_fn (), result_let_binding, __FUNCTION__)

(* What about a top-level let with no args? *)
let top_level_value = __FUNCTION__

(* What about a curried function? *)
let curried a b = let _ = a + b in __FUNCTION__

(* What about inside a module? *)
module Inner = struct
  let from_module () = __FUNCTION__
end

(* [%call_pos] turns out NOT to be in upstream OCaml as of 5.4 —
   it's a Jane Street experimental extension. Confirmed: this errors with
   "Uninterpreted extension 'call_pos'". Skipped from this verification.
   We'll have to use explicit __POS__ tokens at call sites. *)

let () =
  let print_pos label (f, l, c1, c2) =
    Printf.printf "  %-32s %s:%d:%d-%d\n" label f l c1 c2
  in
  let print_str label s =
    Printf.printf "  %-32s %s\n" label s
  in
  print_endline "=== __POS__ ===";
  print_pos "pos_at_top (line 5)" pos_at_top;
  print_endline "";
  print_endline "=== __FUNCTION__ ===";
  print_str "function_at_top" function_at_top;
  let (lam, fn, let_b, outer) = outer_fn () in
  print_str "inside outer_fn, lambda" lam;
  print_str "inside outer_fn, named fn" fn;
  print_str "inside outer_fn, let-bind" let_b;
  print_str "inside outer_fn, body" outer;
  print_str "top_level_value" top_level_value;
  print_str "curried 1 2" (curried 1 2);
  print_str "Inner.from_module ()" (Inner.from_module ());
  print_endline "";
  print_endline "=== [%call_pos] ===";
  print_endline "  NOT IN UPSTREAM OCAML 5.4 — Jane Street experimental only.";
  print_endline "  Conclusion: must use explicit __POS__ at call sites.";
  ()
