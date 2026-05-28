(* K2 — Parallel quicksort.

   Recursive partitioning.  Each level halves the problem (roughly)
   and forks both halves via [join].  Unlike fib, the chunks at each
   level have unequal sizes (skewed by pivot choice), so this
   exercises the stealing path more than fib.

   Apples-to-apples note: an earlier draft compared [Eta.Par.par_sort]
   against [Array.sort], but [Array.sort] is the stdlib's
   merge/heapsort hybrid — a different algorithm.  The reported
   "speedup" then mixed algorithmic difference with parallelism.
   This kernel now uses a serial 3-way quicksort with the same pivot
   and partition strategy as [par_sort], so the speedup measures the
   parallel scheduler in isolation. *)

let n_default = 1_000_000
let n_quick = 250_000

let make_array n seed =
  let st = Random.State.make [| seed |] in
  Array.init n (fun _ -> Random.State.int st 1_000_000_000)

let is_sorted arr =
  let ok = ref true in
  for i = 1 to Array.length arr - 1 do
    if arr.(i) < arr.(i - 1) then ok := false
  done;
  !ok

let checksum arr =
  let n = Array.length arr in
  Printf.sprintf "%d:%d:%d" n arr.(0) arr.(n - 1)

(* --- Serial 3-way quicksort, mirroring par's par_sort -------- *)

let swap arr i j =
  if i <> j then begin
    let t = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- t
  end

let isort arr lo hi =
  for i = lo + 1 to hi do
    let x = arr.(i) in
    let mutable j = i - 1 in
    while j >= lo && compare arr.(j) x > 0 do
      arr.(j + 1) <- arr.(j);
      j <- j - 1
    done;
    arr.(j + 1) <- x
  done

let median_of_three arr a b c =
  if compare arr.(a) arr.(b) < 0 then
    if compare arr.(b) arr.(c) < 0 then b
    else if compare arr.(a) arr.(c) < 0 then c
    else a
  else if compare arr.(a) arr.(c) < 0 then a
  else if compare arr.(b) arr.(c) < 0 then c
  else b

let partition3 arr lo hi =
  let mid = lo + ((hi - lo) / 2) in
  let p = median_of_three arr lo mid hi in
  swap arr lo p;
  let pivot = arr.(lo) in
  let mutable lt = lo in
  let mutable gt = hi in
  let mutable i = lo + 1 in
  while i <= gt do
    let c = compare arr.(i) pivot in
    if c < 0 then begin
      swap arr lt i;
      lt <- lt + 1;
      i <- i + 1
    end else if c > 0 then begin
      swap arr i gt;
      gt <- gt - 1
    end else
      i <- i + 1
  done;
  (lt, gt)

let qsort_threshold = 32

let rec serial_qsort arr lo hi =
  let len = hi - lo + 1 in
  if len <= qsort_threshold then isort arr lo hi
  else begin
    let lt, gt = partition3 arr lo hi in
    serial_qsort arr lo (lt - 1);
    serial_qsort arr (gt + 1) hi
  end

let serial_sort arr =
  let n = Array.length arr in
  if n > 1 then serial_qsort arr 0 (n - 1)

let name = "qsort"
let description =
  "Same 3-way quicksort, serial vs Eta.Par.par_sort over a random int array"

let run_serial ~quick () =
  let n = if quick then n_quick else n_default in
  let arr = make_array n 0xC0FFEE in
  serial_sort arr;
  assert (is_sorted arr);
  checksum arr

let run_parallel ~quick pool =
  let n = if quick then n_quick else n_default in
  let arr = make_array n 0xC0FFEE in
  Eta.Par.Pool.run pool (fun () -> Eta.Par.par_sort arr compare);
  assert (is_sorted arr);
  checksum arr
