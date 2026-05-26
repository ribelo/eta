(* K1 — Recursive Fibonacci.

   Balanced binary recursion tree.  Classic fork-join workload, exercises
   spawn/finish on a regular tree where every internal node forks two
   children of similar weight.  Below [cutoff] the recursion runs serially. *)

let cutoff = 20

let rec fib_serial n =
  if n < 2 then n else fib_serial (n - 1) + fib_serial (n - 2)

let rec fib_par n =
  if n <= cutoff then fib_serial n
  else
    let a, b =
      Par.join (fun () -> fib_par (n - 1)) (fun () -> fib_par (n - 2))
    in
    a + b

let n_default = 43
let n_quick = 40

let name = "fib"
let description = "fib(n) via join, cutoff=20 — balanced recursion tree"

let run_serial ~quick () =
  let n = if quick then n_quick else n_default in
  string_of_int (fib_serial n)

let run_parallel ~quick pool =
  let n = if quick then n_quick else n_default in
  string_of_int (Par.Pool.run pool (fun () -> fib_par n))
