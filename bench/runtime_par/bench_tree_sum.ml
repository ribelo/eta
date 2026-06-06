(* Mirror of chili's overhead.rs — measure the cost of [join] on a
   small balanced binary tree (high-overhead regime) and a large one
   (parallelism regime).

   For each layer count we time:

   - [baseline] : pure recursion, no scheduler.
   - [par]  : same recursion using [Eta_par.join].

   Tree representation: [Leaf | Node of int * tree * tree], the
   most direct OCaml equivalent of chili's
   [Option<Box<Node>>].  An unboxed [Leaf] (immediate int) plus a
   3-field [Node] block per internal node — one pointer indirection
   per child, matching Rust's null-pointer-optimised
   [Option<Box<_>>].  A previous version of this bench used [tree
   option] which added a redundant [Some]-box per child and made the
   OCaml baseline ~3-5x slower than Rust's, distorting the
   comparison. *)

type tree = Leaf | Node of int * tree * tree

let rec make_tree layers =
  if layers <= 0 then Leaf
  else Node (1, make_tree (layers - 1), make_tree (layers - 1))

let rec sum_serial t =
  match t with
  | Leaf -> 0
  | Node (v, l, r) -> v + sum_serial l + sum_serial r

let rec sum_par t =
  match t with
  | Leaf -> 0
  | Node (v, l, r) ->
    let sl, sr =
      Eta_par.join (fun () -> sum_par l) (fun () -> sum_par r)
    in
    v + sl + sr

let time_ns f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  (r, t1 -. t0)

let median ts =
  let sorted = List.sort compare ts in
  List.nth sorted (List.length sorted / 2)

let format_time s =
  if s >= 1.0 then Printf.sprintf "%.2f s" s
  else if s >= 1e-3 then Printf.sprintf "%.2f ms" (s *. 1000.0)
  else if s >= 1e-6 then Printf.sprintf "%.2f µs" (s *. 1e6)
  else Printf.sprintf "%.2f ns" (s *. 1e9)

let bench_one ~layers ~iters ~n_workers =
  let t = make_tree layers in
  let n = (1 lsl layers) - 1 in
  let expected = n in
  (* Serial / baseline. *)
  let serial_warmup = sum_serial t in
  assert (serial_warmup = expected);
  let serial_times =
    List.init iters (fun _ ->
      let r, dt = time_ns (fun () -> sum_serial t) in
      assert (r = expected);
      dt)
  in
  let t_serial = median serial_times in
  (* Eta_par. *)
  let t_par =
    Eta_par.Pool.with_pool ~n_workers (fun pool ->
      let warm = Eta_par.Pool.run pool (fun () -> sum_par t) in
      assert (warm = expected);
      let times =
        List.init iters (fun _ ->
          let r, dt =
            time_ns (fun () -> Eta_par.Pool.run pool (fun () -> sum_par t))
          in
          assert (r = expected);
          dt)
      in
      median times)
  in
  (n, t_serial, t_par)

let () =
  let layers_list = ref [10; 24] in
  let iters = ref 5 in
  let n_workers = ref 4 in
  let rec parse i =
    if i >= Array.length Sys.argv then ()
    else match Sys.argv.(i) with
      | "--layers" ->
        layers_list := List.map int_of_string
                         (String.split_on_char ',' Sys.argv.(i + 1));
        parse (i + 2)
      | "--iters" -> iters := int_of_string Sys.argv.(i + 1); parse (i + 2)
      | "--workers" -> n_workers := int_of_string Sys.argv.(i + 1); parse (i + 2)
      | s -> Printf.eprintf "unknown arg %S\n" s; exit 2
  in
  parse 1;
  Printf.printf
    "tree_sum overhead bench (mirrors chili's overhead.rs)\n\
     workers=%d  iters=%d\n\n"
    !n_workers !iters;
  Printf.printf "%-10s %-12s %-14s %-14s %-10s\n"
    "layers" "n_nodes" "baseline" "par" "speedup";
  Printf.printf "%s\n" (String.make 64 '-');
  List.iter (fun layers ->
    let n, t_ser, t_par = bench_one ~layers ~iters:!iters ~n_workers:!n_workers in
    Printf.printf "%-10d %-12d %-14s %-14s %-10.2fx\n"
      layers n (format_time t_ser) (format_time t_par) (t_ser /. t_par);
    Printf.printf
      "METRIC TREE_LAYERS_%d_BASELINE_NS=%.0f\n" layers (t_ser *. 1e9);
    Printf.printf
      "METRIC TREE_LAYERS_%d_PAR_NS=%.0f\n" layers (t_par *. 1e9))
    !layers_list
