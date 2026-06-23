(* alloc_probe.ml — hit-path allocation: intrusive LRU vs reinsertion LRU.

   Tests the recommendation's Q4/Q5 claim: "intrusive LRU is low-allocation on
   hit; reinsertion-LRU (Effect's approach) allocates on every hit." Pure stdlib.
   Compile + run inside the repo's Nix shell:
     nix develop -c ocamlopt -O3 alloc_probe.ml -o /tmp/eta-cache-alloc-probe
     nix develop -c /tmp/eta-cache-alloc-probe

   Method: pre-populate to capacity, then N hits on warm keys. Measure
   Gc.minor_words + major allocations before/after. Report words/hit. *)

module Intrusive = struct
  type node = {
    key : int;
    mutable prev : node option;
    mutable next : node option;
    mutable value : int;
  }

  type t = {
    mutable head : node option;
    mutable tail : node option;
    table : (int, node) Hashtbl.t;
  }

  let create n = { head = None; tail = None; table = Hashtbl.create n }

  let unlink t n =
    (match n.prev with Some p -> p.next <- n.next | None -> t.head <- n.next);
    (match n.next with Some s -> s.prev <- n.prev | None -> t.tail <- n.prev)

  let push_head t n =
    n.prev <- None;
    n.next <- t.head;
    (match t.head with Some h -> h.prev <- Some n | None -> t.tail <- Some n);
    t.head <- Some n

  let insert t k v =
    (try ignore (Hashtbl.find t.table k : node)
     with Not_found ->
       let n = { key = k; prev = None; next = None; value = v } in
       Hashtbl.add t.table k n;
       push_head t n)

  (* hit path: relink to head in place — the thing we measure *)
  let hit t k =
    match Hashtbl.find_opt t.table k with
    | None -> ()
    | Some n -> unlink t n; push_head t n
end

module Intrusive_sentinel = struct
  (* No [option] pointers: an index/sentinel shape removes [Some] boxing from
     relinking, leaving the [Hashtbl.find_opt] result as the visible allocation
     floor in this stdlib probe. *)
  type node = {
    key : int;
    mutable value : int;
    mutable prev : int;  (* index into [nodes], -1 = none *)
    mutable next : int;
  }

  type t = {
    mutable nodes : node array;
    mutable count : int;
    capacity : int;
    mutable head : int;
    mutable tail : int;
    table : (int, int) Hashtbl.t;  (* key -> index *)
  }

  let dummy = { key = -1; value = 0; prev = -1; next = -1 }

  let create n =
    {
      nodes = Array.make n dummy;
      count = 0;
      capacity = n;
      head = -1;
      tail = -1;
      table = Hashtbl.create n;
    }

  let unlink t i =
    let p = t.nodes.(i).prev and s = t.nodes.(i).next in
    if p >= 0 then t.nodes.(p).next <- s else t.head <- s;
    if s >= 0 then t.nodes.(s).prev <- p else t.tail <- p

  let push_head t i =
    t.nodes.(i).prev <- -1;
    t.nodes.(i).next <- t.head;
    if t.head >= 0 then t.nodes.(t.head).prev <- i else t.tail <- i;
    t.head <- i

  (* we only need the hit path here; insert is a simplified no-evict for the
     micro-benchmark (pre-populated exactly to capacity). *)
  let insert t k v =
    let i = t.count in
    t.nodes.(i) <- { key = k; value = v; prev = -1; next = -1 };
    t.count <- i + 1;
    Hashtbl.add t.table k i;
    push_head t i

  (* hit path: move node to front of the recency list, in place. Pure mutation. *)
  let hit t k =
    match Hashtbl.find_opt t.table k with
    | None -> ()
    | Some i ->
        if i <> t.head then (unlink t i; push_head t i)
end

module Reinsertion = struct
  type t = {
    table : (int, int) Hashtbl.t;
    mutable order : int list;
    capacity : int;
  }

  let create n = { table = Hashtbl.create n; order = []; capacity = n }

  let insert t k v =
    Hashtbl.replace t.table k v;
    t.order <- t.order @ [ k ];
    if List.length t.order > t.capacity then
      match t.order with
      | old :: rest -> t.order <- rest; Hashtbl.remove t.table old
      | [] -> ()

  (* hit path: remove + re-add to move to end — allocates (Effect's reinsertion). *)
  let hit t k =
    match Hashtbl.find_opt t.table k with
    | None -> ()
    | Some v ->
        Hashtbl.remove t.table k;
        Hashtbl.replace t.table k v;
        t.order <- (List.filter (fun x -> x <> k) t.order) @ [ k ]
end

let measure label warmup iters f =
  for _ = 1 to warmup do ignore (f ()) done;
  Gc.minor ();
  let stat0 = Gc.stat () in
  for _ = 1 to iters do ignore (f ()) done;
  let stat1 = Gc.stat () in
  let minor = stat1.Gc.minor_words -. stat0.Gc.minor_words in
  let major = stat1.Gc.major_words -. stat0.Gc.major_words in
  let per_hit = (minor +. major) /. float iters in
  Printf.printf "%-24s %10.3f words/hit  (minor=%.1f major=%.1f over %d)\n"
    label per_hit minor major iters

let () =
  let cap = 256 in
  let keys = Array.init cap (fun i -> i) in
  (* baseline: the measurement harness itself (closure call + Random), no cache *)
  measure "baseline (harness only)" 1000 1_000_000 (fun () ->
      ignore (keys.(Random.int cap));
      1);
  let ti = Intrusive.create cap in
  Array.iter (fun k -> Intrusive.insert ti k (k * 2)) keys;
  measure "intrusive LRU hit" 1000 1_000_000 (fun () ->
      Intrusive.hit ti (keys.(Random.int cap));
      1);
  let ts = Intrusive_sentinel.create cap in
  Array.iter (fun k -> Intrusive_sentinel.insert ts k (k * 2)) keys;
  measure "intrusive-sentinel hit" 1000 1_000_000 (fun () ->
      Intrusive_sentinel.hit ts (keys.(Random.int cap));
      1);
  let tr = Reinsertion.create cap in
  Array.iter (fun k -> Reinsertion.insert tr k (k * 2)) keys;
  measure "reinsertion LRU hit" 1000 100_000 (fun () ->
      Reinsertion.hit tr (keys.(Random.int cap));
      1);
  Printf.printf "\nLower words/hit = less allocation on the hit path.\n";
  Printf.printf "Expect sentinel-intrusive near the Hashtbl.find_opt floor and reinsertion much higher.\n"
