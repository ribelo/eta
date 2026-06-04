(* Eta.Par array and sorting combinators. *)

let join = Par_runtime.join
let join_unit = Par_runtime.join_unit
let chunk_or_default = Par_runtime.chunk_or_default

(* --------------------------------------------------------------------------- *)
(* par_for, par_iter, par_iteri, par_map, par_mapi, par_reduce.

   All implemented as recursive halving with [join]. Heartbeat
   ensures parallelism happens at the right granularity automatically;
   the [chunk] parameter only sets the leaf size below which we stop
   recursing. *)

let rec par_for_rec ~chunk ~start ~stop (f @ many) =
  let len = stop - start in
  if len <= chunk then
    for i = start to stop - 1 do f i done
  else begin
    let mid = start + (len / 2) in
    join_unit
      (fun () -> par_for_rec ~chunk ~start ~stop:mid f)
      (fun () -> par_for_rec ~chunk ~start:mid ~stop f)
  end

let par_for ?chunk ~start ~stop (f @ many) =
  let chunk = chunk_or_default chunk in
  if start >= stop then ()
  else if stop - start <= chunk then
    for i = start to stop - 1 do f i done
  else
    par_for_rec ~chunk ~start ~stop f

let par_iter ?chunk arr (f @ many) =
  par_for ?chunk ~start:0 ~stop:(Array.length arr) (fun i -> f arr.(i))

let par_iteri ?chunk arr (f @ many) =
  par_for ?chunk ~start:0 ~stop:(Array.length arr) (fun i -> f i arr.(i))

let rec par_map_rec out (arr : 'a array) (f @ many) ~chunk ~start ~stop =
  let len = stop - start in
  if len <= chunk then
    for i = start to stop - 1 do out.(i) <- f arr.(i) done
  else begin
    let mid = start + (len / 2) in
    join_unit
      (fun () -> par_map_rec out arr f ~chunk ~start ~stop:mid)
      (fun () -> par_map_rec out arr f ~chunk ~start:mid ~stop)
  end

let par_map ?chunk (arr : 'a array) (f @ many) =
  let n = Array.length arr in
  if n = 0 then [||]
  else begin
    let out = Array.make n (f arr.(0)) in
    let chunk = chunk_or_default chunk in
    par_map_rec out arr f ~chunk ~start:1 ~stop:n;
    out
  end

let rec par_mapi_rec out (arr : 'a array) (f @ many) ~chunk ~start ~stop =
  let len = stop - start in
  if len <= chunk then
    for i = start to stop - 1 do out.(i) <- f i arr.(i) done
  else begin
    let mid = start + (len / 2) in
    join_unit
      (fun () -> par_mapi_rec out arr f ~chunk ~start ~stop:mid)
      (fun () -> par_mapi_rec out arr f ~chunk ~start:mid ~stop)
  end

let par_mapi ?chunk (arr : 'a array) (f @ many) =
  let n = Array.length arr in
  if n = 0 then [||]
  else begin
    let out = Array.make n (f 0 arr.(0)) in
    let chunk = chunk_or_default chunk in
    par_mapi_rec out arr f ~chunk ~start:1 ~stop:n;
    out
  end

let rec par_reduce_rec arr ~chunk ~start ~stop ~init ~(map @ many)
    ~(combine @ many) =
  let len = stop - start in
  if len = 0 then init
  else if len <= chunk then begin
    let acc = ref init in
    for i = start to stop - 1 do
      acc := combine !acc (map arr.(i))
    done;
    !acc
  end
  else begin
    let mid = start + (len / 2) in
    let l, r =
      join
        (fun () -> par_reduce_rec arr ~chunk ~start ~stop:mid ~init ~map ~combine)
        (fun () -> par_reduce_rec arr ~chunk ~start:mid ~stop ~init ~map ~combine)
    in
    combine l r
  end

let par_reduce ?chunk arr ~init ~(map @ many) ~(combine @ many) =
  let chunk = chunk_or_default chunk in
  par_reduce_rec arr ~chunk ~start:0 ~stop:(Array.length arr) ~init ~map ~combine

(* --------------------------------------------------------------------------- *)
(* par_sort: parallel quicksort with 3-way (Dutch national flag)
   partitioning.

   The 3-way partition collapses runs of pivot-equal elements into a
   single middle segment, so [par_sort] on an all-equal array
   degenerates to one partition + zero recursion (instead of O(N)
   recursion as Lomuto would). *)

let swap (arr : 'a array) i j =
  if i <> j then begin
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  end

let serial_isort arr (cmp @ many) lo hi =
  for i = lo + 1 to hi do
    let x = arr.(i) in
    let mutable j = i - 1 in
    while j >= lo && cmp arr.(j) x > 0 do
      arr.(j + 1) <- arr.(j);
      j <- j - 1
    done;
    arr.(j + 1) <- x
  done

let median_of_three arr (cmp @ many) a b c =
  if cmp arr.(a) arr.(b) < 0 then
    if cmp arr.(b) arr.(c) < 0 then b
    else if cmp arr.(a) arr.(c) < 0 then c
    else a
  else
    if cmp arr.(a) arr.(c) < 0 then a
    else if cmp arr.(b) arr.(c) < 0 then c
    else b

(* Three-way partition. Returns [(lt, gt)] such that:
   - [lo .. lt-1]  : elements < pivot
   - [lt .. gt]    : elements = pivot (no further sorting needed)
   - [gt+1 .. hi]  : elements > pivot *)
let partition3 arr (cmp @ many) lo hi =
  (* Pivot = median of three; move it to [lo]. *)
  let mid = lo + ((hi - lo) / 2) in
  let p = median_of_three arr cmp lo mid hi in
  swap arr lo p;
  let pivot = arr.(lo) in
  let mutable lt = lo in
  let mutable gt = hi in
  let mutable i = lo + 1 in
  while i <= gt do
    let c = cmp arr.(i) pivot in
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

let rec par_qsort arr (cmp @ many) lo hi =
  let len = hi - lo + 1 in
  if len <= qsort_threshold then serial_isort arr cmp lo hi
  else begin
    let lt, gt = partition3 arr cmp lo hi in
    join_unit
      (fun () -> par_qsort arr cmp lo (lt - 1))
      (fun () -> par_qsort arr cmp (gt + 1) hi)
  end

let par_sort arr (cmp @ many) =
  let n = Array.length arr in
  if n > 1 then par_qsort arr cmp 0 (n - 1)
