(* K7 — Dense matrix multiply.

   N×N float matmul, parallelized via par_for over rows.  Compute-bound
   (O(N^3) flops over O(N^2) memory), regular load per row, no
   inter-row dependencies.

   This is the "easiest possible" parallel workload and a good upper
   bound on achievable speedup: anything less means scheduling overhead. *)

let n_default = 384
let n_quick = 192

(* Row-major flat arrays of float, length n*n. *)
let make_matrix n seed =
  let st = Random.State.make [| seed |] in
  Array.init (n * n) (fun _ -> Random.State.float st 1.0)

let matmul_row n a b c i =
  (* c.(i*n + j) = sum_k a.(i*n+k) * b.(k*n+j) *)
  let row_a = i * n in
  for j = 0 to n - 1 do
    let acc = ref 0.0 in
    for k = 0 to n - 1 do
      acc := !acc +. a.(row_a + k) *. b.(k * n + j)
    done;
    c.(row_a + j) <- !acc
  done

let serial_matmul n a b =
  let c = Array.make (n * n) 0.0 in
  for i = 0 to n - 1 do
    matmul_row n a b c i
  done;
  c

let parallel_matmul n a b =
  let c = Array.make (n * n) 0.0 in
  (* Each row is heavy work (~n^2 multiply-adds); chunking by 1 row
     means one task per row. *)
  Eta.Par.par_for ~chunk:1 ~start:0 ~stop:n (fun i -> matmul_row n a b c i);
  c

let checksum c =
  (* Sum and last few elements; rounded to bypass float-order differences. *)
  let n = Array.length c in
  let s = ref 0.0 in
  for i = 0 to n - 1 do
    s := !s +. c.(i)
  done;
  Printf.sprintf "%.1f" !s

let name = "matmul"
let description = "Dense N×N float matmul, par_for over rows"

let run_serial ~quick () =
  let n = if quick then n_quick else n_default in
  let a = make_matrix n 1 in
  let b = make_matrix n 2 in
  checksum (serial_matmul n a b)

let run_parallel ~quick pool =
  let n = if quick then n_quick else n_default in
  let a = make_matrix n 1 in
  let b = make_matrix n 2 in
  checksum (Eta.Par.Pool.run pool (fun () -> parallel_matmul n a b))
