(* Candidate B: a public Channel / ZChannel-like core.

   This is the candidate the original V-S1/V-S6 decision rejected on the claim
   that "making Channel public imports seven parameters". This probe tests that
   claim directly in OCaml:

     1. Can a public Channel express a REAL streaming transducer
        (chunk-by-chunk, leftover state, terminal done value, distinct
        upstream-EOF vs upstream-error)?
     2. How many type parameters does an Eta-shaped Channel actually need?
     3. Do ordinary call sites need type annotations, or does inference handle
        them?

   The model is a faithful (mini) ZChannel: write / succeed / fail / readWith.
   It is a runnable interpreter, not production code. *)

open Stream_core_reopen_common

(* The Channel core.

   OCaml parameter count: 5, NOT 7.

     'out_elem  'out_done  'in_elem  'in_done  'err

   Effect-TS / Scala carry 7 (OutElem, OutErr, OutDone, InElem, InErr, InDone,
   Env). Two collapse because Eta streams have a single typed-error row (InErr
   and OutErr become one 'err), and Env is absorbed into the embedded
   [('a,'err) Effect.t] exactly as the real eta_stream already does. *)
type ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel =
  | C_done of 'out_done
  | C_fail of 'err
  | C_emit of 'out_elem * ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel
  | C_read of
      ('in_elem -> ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel)
      * ('in_done -> ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel)
      * ('err -> ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel)

(* ---- constructors ------------------------------------------------------- *)

(* A pure source: write all of [xs], then finish with [done]. A source never
   reads, so its [in_*] params stay free. *)
let rec source (xs : 'a list) (done_ : 'd)
  : ('a, 'd, 'in_elem, 'in_done, 'err) channel =
  match xs with
  | [] -> C_done done_
  | x :: rest -> C_emit (x, source rest done_)

let succeed (done_ : 'd) : (_, 'd, 'in_elem, 'in_done, 'err) channel =
  C_done done_

(* map over output elements. Call site needs NO type annotations. *)
let rec map (f : 'a -> 'b)
    (c : ('a, 'd, 'i, 'id, 'err) channel)
  : ('b, 'd, 'i, 'id, 'err) channel =
  match c with
  | C_emit (a, rest) -> C_emit (f a, map f rest)
  | C_done d -> C_done d
  | C_fail e -> C_fail e
  | C_read (oe, od, of_) ->
      C_read ((fun x -> map f (oe x)), (fun d -> map f (od d)), (fun e -> map f (of_ e)))

(* take n from the output, then finish with the count consumed. *)
let rec take (n : int) (c : ('a, 'd, 'i, 'id, 'err) channel)
  : ('a, int, 'i, 'id, 'err) channel =
  if n <= 0 then C_done 0
  else
    match c with
    | C_emit (a, rest) -> C_emit (a, take (n - 1) rest)
    | C_done _ -> C_done 0
    | C_fail e -> C_fail e
    | C_read (oe, od, of_) ->
        C_read ((fun x -> take n (oe x)), (fun d -> take n (od d)), (fun e -> take n (of_ e)))

(* ---- the decisive transducer: streaming split_lines --------------------- *)

(* Real streaming behaviour:
     - consume chunk by chunk
     - carry leftover bytes across chunk boundaries
     - emit every complete line as soon as it is found (0..N per chunk)
     - on upstream clean EOF, emit the final partial line (if any) as the
       terminal done value, NOT as an element
     - on upstream error, propagate; do not emit anything.

   [carry] is the leftover held in the channel state between reads. *)
let rec split_lines (carry : string)
  : (string, string, string, 'in_done, 'err) channel =
  C_read
    ( (* on_elem *) (fun chunk ->
        let buf = carry ^ chunk in
        let len = String.length buf in
        let rec explode start acc i =
          if i = len then emit_all acc (split_lines (String.sub buf start (len - start)))
          else if buf.[i] = '\n' then
            explode (i + 1) (String.sub buf start (i - start) :: acc) (i + 1)
          else explode start acc (i + 1)
        in
        explode 0 [] 0),
      (* on_done *) (fun _ -> if carry = "" then C_done "" else C_done carry),
      (* on_fail *) (fun e -> C_fail e) )

and emit_all (lines_rev : string list) (k : (_, _, _, _, _) channel)
  : (_, _, _, _, _) channel =
  match lines_rev with
  | [] -> k
  | x :: rest -> C_emit (x, emit_all rest k)

(* ---- running a transducer against a source ------------------------------ *)

(* A source only emits, finishes, or fails. [step_source] peels exactly one
   upstream signal so failure is observed once. *)
type ('i, 'id, 'sx, 'sxd, 'err) source_step =
  | S_elem of 'i * ('i, 'id, 'sx, 'sxd, 'err) channel
  | S_done of 'id
  | S_fail of 'err

let step_source (src : ('i, 'id, 'sx, 'sxd, 'err) channel) :
    ('i, 'id, 'sx, 'sxd, 'err) source_step =
  match src with
  | C_emit (x, k) -> S_elem (x, k)
  | C_done d -> S_done d
  | C_fail e -> S_fail e
  | C_read _ -> failwith "source must not read"

let rec run (src : ('i, 'id, 'sx, 'sxd, 'err) channel)
    (td : ('o, 'od, 'i, 'id, 'err) channel)
    (on_elem : 'o -> unit) (on_done : 'od -> unit) (on_fail : 'err -> unit)
  : unit =
  match td with
  | C_done d -> on_done d
  | C_fail e -> on_fail e
  | C_emit (o, k) -> on_elem o; run src k on_elem on_done on_fail
  | C_read (oe, od, of_) ->
      (match step_source src with
       | S_elem (x, k) -> run k (oe x) on_elem on_done on_fail
       | S_done d -> run src (od d) on_elem on_done on_fail
       | S_fail e -> run src (of_ e) on_elem on_done on_fail)

(* ---- demonstration ------------------------------------------------------ *)

let () =
  (* Source emits three byte chunks, then a terminal unit.
     Full input "a\nb\ncd" splits into lines a, b and a trailing partial "cd". *)
  let src = source [ "a\nb"; "\nc"; "d" ] () in
  let td = split_lines "" in
  let lines = ref [] in
  let terminal = ref None in
  run src td
    (fun line -> lines := line :: !lines)
    (fun leftover -> terminal := Some leftover)
    (fun _err -> ());
  Printf.printf "split_lines emitted: %s\n" (String.concat " | " (List.rev !lines));
  Printf.printf "split_lines terminal leftover: %s\n"
    (match !terminal with None -> "<none>" | Some s -> s)

(* ---- call-site inference check ------------------------------------------ *)
(* This block exists only to compile: ordinary call sites infer without
   annotations. [map] and [take] were applied with no type hints. *)
let _use_map () =
  let s = source [ 1; 2; 3 ] () in
  let s' = map (fun n -> n * 2) s in
  let s'' = take 2 s' in
  ignore (s'' : (int, int, _, _, _) channel)
