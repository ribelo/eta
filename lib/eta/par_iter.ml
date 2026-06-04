(* Eta.Par lazy parallel iterators. *)

let join = Par_runtime.join
let chunk_or_default = Par_runtime.chunk_or_default

type 'a producer = {
  len : int;
  at : (int -> 'a) @@ many;
}

type ('a, 'r) consumer = {
  split_at :
    (int -> ('a, 'r) consumer * ('a, 'r) consumer * ('r -> 'r -> 'r)) @@ many;
  fold_seq : ((int -> 'a) -> start:int -> stop:int -> 'r) @@ many;
  full : (unit -> bool) @@ many;
}

type 'a t = {
  drive : 'r. ('a, 'r) consumer -> 'r;
}

let rec bridge : type a r.
    a producer -> (a, r) consumer ->
    chunk:int -> start:int -> stop:int -> r =
 fun p c ~chunk ~start ~stop ->
  if c.full () then
    c.fold_seq p.at ~start ~stop
  else
    let len = stop - start in
    if len <= chunk then
      c.fold_seq p.at ~start ~stop
    else
      let mid = start + (len / 2) in
      let lc, rc, reduce = c.split_at mid in
      let lr, rr =
        join
          (fun () -> bridge p lc ~chunk ~start ~stop:mid)
          (fun () -> bridge p rc ~chunk ~start:mid ~stop)
      in
      reduce lr rr

(* Constructors. *)

let of_array ?chunk (arr : 'a array) : 'a t =
  let p = { len = Array.length arr; at = Array.unsafe_get arr } in
  {
    drive =
      (fun c ->
        bridge p c ~chunk:(chunk_or_default chunk) ~start:0 ~stop:p.len);
  }

let of_range ?chunk ~start ~stop () : int t =
  if stop < start then invalid_arg "Eta.Par.Iter.of_range: stop < start";
  let len = stop - start in
  let p = { len; at = (fun i -> start + i) } in
  {
    drive =
      (fun c ->
        bridge p c ~chunk:(chunk_or_default chunk) ~start:0 ~stop:p.len);
  }

let of_array_sub ?chunk (arr : 'a array) ~start ~stop : 'a t =
  if start < 0 || stop > Array.length arr || stop < start then
    invalid_arg "Eta.Par.Iter.of_array_sub: bad indices";
  let len = stop - start in
  let p = { len; at = (fun i -> Array.unsafe_get arr (start + i)) } in
  {
    drive =
      (fun c ->
        bridge p c ~chunk:(chunk_or_default chunk) ~start:0 ~stop:p.len);
  }

(* Adapters. *)

let map (f @ many) (it : 'a t) =
  let drive : type r. ('b, r) consumer -> r =
   fun b_consumer ->
    let rec adapt (b : ('b, r) consumer) : ('a, r) consumer =
      {
        split_at =
          (fun mid ->
            let l, r, red = b.split_at mid in
            (adapt l, adapt r, red));
        fold_seq =
          (fun a_at ~start ~stop ->
            b.fold_seq (fun i -> f (a_at i)) ~start ~stop);
        full = b.full;
      }
    in
    it.drive (adapt b_consumer)
  in
  { drive }

let mapi (f @ many) (it : 'a t) =
  let drive : type r. ('b, r) consumer -> r =
   fun b_consumer ->
    let rec adapt (b : ('b, r) consumer) : ('a, r) consumer =
      {
        split_at =
          (fun mid ->
            let l, r, red = b.split_at mid in
            (adapt l, adapt r, red));
        fold_seq =
          (fun a_at ~start ~stop ->
            b.fold_seq (fun i -> f i (a_at i)) ~start ~stop);
        full = b.full;
      }
    in
    it.drive (adapt b_consumer)
  in
  { drive }

let filter (p @ many) (it : 'a t) =
  let drive : type r. ('a, r) consumer -> r =
   fun a_consumer ->
    let rec adapt (b : ('a, r) consumer) : ('a, r) consumer =
      {
        split_at =
          (fun mid ->
            let l, r, red = b.split_at mid in
            (adapt l, adapt r, red));
        fold_seq =
          (fun at ~start ~stop ->
            let n_in = stop - start in
            let kept = Array.make n_in (Obj.magic 0 : 'a) in
            let n = ref 0 in
            for i = start to stop - 1 do
              let x = at i in
              if p x then begin
                kept.(!n) <- x;
                incr n
              end
            done;
            b.fold_seq
              (fun i -> Array.unsafe_get kept i)
              ~start:0 ~stop:!n);
        full = b.full;
      }
    in
    it.drive (adapt a_consumer)
  in
  { drive }

(* Consumers. *)

let for_each (f @ many) (it : 'a t) =
  let rec consumer : ('a, unit) consumer = {
    split_at = (fun _mid -> (consumer, consumer, fun () () -> ()));
    fold_seq =
      (fun at ~start ~stop ->
        for i = start to stop - 1 do f (at i) done);
    full = (fun () -> false);
  } in
  it.drive consumer

let iter = for_each

let reduce ~(init : 'a) ~(combine @ many) (it : 'a t) =
  let rec consumer : ('a, 'a) consumer = {
    split_at = (fun _mid -> (consumer, consumer, combine));
    fold_seq =
      (fun at ~start ~stop ->
        let acc = ref init in
        for i = start to stop - 1 do
          acc := combine !acc (at i)
        done;
        !acc);
    full = (fun () -> false);
  } in
  it.drive consumer

let fold ~(init : 'b) ~(step @ many) ~(combine @ many) (it : 'a t) =
  let rec consumer : ('a, 'b) consumer = {
    split_at = (fun _mid -> (consumer, consumer, combine));
    fold_seq =
      (fun at ~start ~stop ->
        let acc = ref init in
        for i = start to stop - 1 do
          acc := step !acc (at i)
        done;
        !acc);
    full = (fun () -> false);
  } in
  it.drive consumer

let sum (it : int t) : int = reduce ~init:0 ~combine:( + ) it

let count (it : 'a t) : int =
  fold ~init:0 ~step:(fun n _ -> n + 1) ~combine:( + ) it

let min_with ~(cmp @ many) (it : 'a t) =
  let combine a b =
    match a, b with
    | None, x | x, None -> x
    | Some x, Some y -> if cmp x y <= 0 then Some x else Some y
  in
  let rec consumer : ('a, 'a option) consumer = {
    split_at = (fun _mid -> (consumer, consumer, combine));
    fold_seq =
      (fun at ~start ~stop ->
        if start >= stop then None
        else begin
          let best = ref (at start) in
          for i = start + 1 to stop - 1 do
            let x = at i in
            if cmp x !best < 0 then best := x
          done;
          Some !best
        end);
    full = (fun () -> false);
  } in
  it.drive consumer

let max_with ~(cmp @ many) it =
  min_with ~cmp:(fun a b -> -(cmp a b)) it

let min it = min_with ~cmp:compare it
let max it = max_with ~cmp:compare it

let collect_array (it : 'a t) : 'a array =
  let rec consumer : ('a, 'a array) consumer = {
    split_at = (fun _mid -> (consumer, consumer, Array.append));
    fold_seq =
      (fun at ~start ~stop ->
        let n = stop - start in
        if n = 0 then [||]
        else begin
          let out = Array.make n (at start) in
          for i = 1 to n - 1 do
            out.(i) <- at (start + i)
          done;
          out
        end);
    full = (fun () -> false);
  } in
  it.drive consumer

let find_any (p @ many) (it : 'a t) =
  let found : 'a option Atomic.t = Atomic.make None in
  let is_full () = Atomic.get found <> None in
  let combine a b = match a with Some _ -> a | None -> b in
  let rec consumer : ('a, 'a option) consumer = {
    split_at = (fun _mid -> (consumer, consumer, combine));
    fold_seq =
      (fun at ~start ~stop ->
        let result = ref None in
        let i = ref start in
        while !result = None && !i < stop && Atomic.get found = None do
          let x = at !i in
          if p x then begin
            result := Some x;
            ignore (Atomic.compare_and_set found None (Some x))
          end;
          incr i
        done;
        !result);
    full = is_full;
  } in
  it.drive consumer

let any (p @ many) (it : 'a t) =
  match find_any p it with
  | Some _ -> true
  | None -> false

let all (p @ many) (it : 'a t) =
  not (any (fun x -> not (p x)) it)
