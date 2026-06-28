(* Candidate A: the current eta_stream shape — public Stream + fold Sink,
   internal-only Channel, pull boundary.

   This probe replicates the REAL eta_stream operator surface (see
   lib/stream/eta_stream.mli): a chunked-pull Stream with map / filter_map /
   scan / flat_map, and a fold Sink. It then tries to implement a REAL
   streaming split_lines and records exactly what the shape can and cannot
   express.

   Conclusion up front (evidence below):
     - [scan] is 1-in-1-out: it emits the accumulator, not the new lines. It
       cannot emit multiple outputs per input chunk.
     - [flat_map] can emit multiple outputs per input, but its mapping function
       has no access to inter-element state, so a streaming splitter is forced
       to hold leftover in an EXTERNAL mutable ref. That mutable ref:
         * is not owned by the stream,
         * is not cleaned up on failure / interruption,
         * is not reset by [retry] (retry replays the source but reuses the
           stale carry),
         * and crucially CANNOT emit the final partial line at all, because
           flat_map only runs its function for emitted elements and there is
           no "after upstream EOF" hook.
     - The terminal partial line is structurally DROPPED. The current shape has
       no typed terminal/done value per stream element pipeline. *)

open Stream_core_reopen_common

(* Faithful replica of eta_stream's public Stream shape:
     type ('a, 'err) t   — element + single typed-error row. *)
type ('a, 'err) stream =
  | S_done
  | S_fail of 'err
  | S_chunk of 'a list * ('a, 'err) stream

let rec from_iterable xs : ('a, 'err) stream =
  match xs with [] -> S_done | x :: rest -> S_chunk ([ x ], from_iterable rest)

let rec map (f : 'a -> 'b) (s : ('a, 'err) stream) : ('b, 'err) stream =
  match s with
  | S_done -> S_done
  | S_fail e -> S_fail e
  | S_chunk (xs, rest) -> S_chunk (List.map f xs, map f rest)

(* scan : ('s -> 'a -> 's) -> 's -> ('a,'err) stream -> ('s,'err) stream
   Emits the accumulator after EACH input. 1-in-1-out. *)
let rec scan (f : 's -> 'a -> 's) (st : 's) (s : ('a, 'err) stream)
  : ('s, 'err) stream =
  match s with
  | S_done -> S_done
  | S_fail e -> S_fail e
  | S_chunk (xs, rest) ->
      let rec emit st acc_rev xs =
        match xs with
        | [] -> S_chunk (List.rev acc_rev, scan f st rest)
        | x :: xr -> let st' = f st x in emit st' (st' :: acc_rev) xr
      in
      emit st [] xs

(* flat_map : ('a -> ('b,'err) stream) -> ('a,'err) stream -> ('b,'err) stream
   The mapping function receives ONE element and returns a stream. It has no
   access to any carry between elements. *)
let rec flat_map (f : 'a -> ('b, 'err) stream) (s : ('a, 'err) stream)
  : ('b, 'err) stream =
  match s with
  | S_done -> S_done
  | S_fail e -> S_fail e
  | S_chunk (xs, rest) -> append_streams (List.map f xs) (fun () -> flat_map f rest)

and append_streams (ss : ('b, 'err) stream list) (k : unit -> ('b, 'err) stream)
  : ('b, 'err) stream =
  match ss with
  | [] -> k ()
  | s :: rest ->
      (match s with
       | S_done -> append_streams rest k
       | S_fail e -> S_fail e
       | S_chunk (ys, srest) -> S_chunk (ys, append_streams (srest :: rest) k))

(* run into a fold. Returns only the folded accumulator; there is NO terminal
   per-pipeline value distinct from the fold result. *)
let rec run_fold (f : 'acc -> 'a -> 'acc) (acc : 'acc) (s : ('a, 'err) stream)
  : ('acc, 'err) result =
  match s with
  | S_done -> Ok acc
  | S_fail e -> Error e
  | S_chunk (xs, rest) -> run_fold f (List.fold_left f acc xs) rest

(* ======================================================================== *)
(* Attempt 1: split_lines via flat_map + an EXTERNAL mutable carry.          *)
(* ======================================================================== *)

(* The only place to hold leftover in the current shape is OUTSIDE the stream. *)
let split_lines_flatmap () =
  let carry = ref "" in
  fun (chunk : string) ->
    let buf = !carry ^ chunk in
    let len = String.length buf in
    let rec explode start acc i =
      if i = len then (acc, String.sub buf start (len - start))
      else if buf.[i] = '\n' then
        explode (i + 1) (String.sub buf start (i - start) :: acc) (i + 1)
      else explode start acc (i + 1)
    in
    let lines_rev, rest = explode 0 [] 0 in
    carry := rest;
    (* Returns complete lines only. The final partial line is LOST: there is no
       callback for "upstream finished, flush your carry". *)
    from_iterable (List.rev lines_rev)

let attempt1 () =
  let carry_split = split_lines_flatmap () in
  let src = from_iterable [ "a\nb"; "\nc"; "d" ] in
  let result = run_fold (fun acc x -> x :: acc) [] (flat_map carry_split src) in
  let lines = match result with Ok acc -> List.rev acc | Error _ -> [] in
  Printf.printf "attempt1 (flat_map+ref) lines: [%s]\n" (String.concat "; " lines);
  Printf.printf "  -> the trailing partial line is DROPPED (no terminal value)\n"

(* ======================================================================== *)
(* Attempt 2: split_lines via scan.                                          *)
(* ======================================================================== *)
(* scan emits the accumulator after each chunk. To recover "lines completed in
   this step" you must DIFF consecutive accumulators — absurd, and still cannot
   emit the terminal partial line. Demonstrated to show scan is the wrong
   abstraction, not a viable one. *)

let attempt2 () =
  (* accumulator = (all_completed_lines_so_far_rev, carry) *)
  let src = from_iterable [ "a\nb"; "\nc"; "d" ] in
  let step (lines_rev, carry) chunk =
    let buf = carry ^ chunk in
    let len = String.length buf in
    let rec explode start acc i =
      if i = len then (acc, String.sub buf start (len - start))
      else if buf.[i] = '\n' then
        explode (i + 1) (String.sub buf start (i - start) :: acc) (i + 1)
      else explode start acc (i + 1)
    in
    let new_rev, rest = explode 0 [] 0 in
    (new_rev @ lines_rev, rest)
  in
  let scanned = scan step ([], "") src in
  let result = run_fold (fun acc x -> x :: acc) [] scanned in
  let accs = match result with Ok acc -> List.rev acc | Error _ -> [] in
  (* scan emits the FULL accumulator each step; recovering per-step deltas would
     require diffing. And the carry in the last accumulator is the trailing
     partial line — recoverable here ONLY by accident, because we folded into a
     list, not because the shape exposes a terminal value. *)
  Printf.printf "attempt2 (scan) emits whole accumulator each step:\n";
  List.iter (fun (ls, carry) ->
    Printf.printf "  step lines=[%s] carry=%S\n" (String.concat "; " ls) carry)
    accs

(* ======================================================================== *)
(* Attempt 3: the honest summary — what the current shape would need.        *)
(* ======================================================================== *)
(* To express split_lines faithfully (leftover, terminal value, distinct
   upstream EOF vs error, retry-safety) the current shape needs EITHER:
     - a NEW primitive (a stateful pull-with-emit + terminal), which is exactly
       a Channel/Transducer by another name; or
     - the ADR-0001 [from_effect_reader]/[unfold_resource] source plus a fold
       that can emit leftovers — i.e. re-inventing a Channel's input side.
   In production this is exactly what happened: lib/http/body/Stream.ml is a
   SEPARATE pull type with [of_reader ~release] and [Chunk|Last|End] terminal
   signals, and lib/http/body/transducer.ml implements gzip as a stateful
   reader with leftover ([Gz.Inf.src_rem]) and a release finalizer — all
   outside eta_stream. *)

let () =
  attempt1 ();
  attempt2 ();
  Printf.printf "\nSummary: the current shape cannot emit a typed terminal value\n";
  Printf.printf "and forces leftover into external state (attempt1) or an\n";
  Printf.printf "accumulator-diff (attempt2). Real transducers were built\n";
  Printf.printf "outside eta_stream (see lib/http/body/{stream,transducer}.ml).\n"
