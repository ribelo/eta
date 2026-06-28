(* Candidate C: a public Pull / Cursor core with explicit close/finalization.

   A pull cursor is the smallest streaming abstraction:

     type 'a pull = unit -> [`Elem of 'a | `End | `Fail of 'err] result

   It is exactly the shape of the current eta_stream pull boundary, made
   first-class and public. The question this probe answers:

     - Can a public Pull express a SOURCE and a simple transform cleanly?
       YES — and more directly than a Channel, because there is no input side.
     - Can a public Pull express a TRANSDUCER (reads upstream, writes
       downstream, holds leftover, returns a terminal value)?
       Only by holding a reference to the upstream pull and pulling from it on
       demand. That mechanism IS the Channel's input side under another name.
       A pull-based transducer either (a) re-invents Channel's read/emit/done
       machinery, or (b) drops the terminal value exactly like candidate A.

   Verdict for C: Pull is the right core for SOURCES and element-wise
   transforms (and is basically what the current eta_stream already is). It is
   NOT sufficient on its own for transducers; the transducer case either grows
   a second pull direction (-> Channel) or loses the terminal value (-> A).
   This keeps C alive as the "small surface" winner for the common case while
   being honest about its transducer limit. *)

open Stream_core_reopen_common

(* A pull cursor: [unit -> step] plus a release finalizer. This is structurally
   identical to lib/http/body/Stream.ml's [of_reader ~release read_fn] and to
   ADR-0001's proposed [from_effect_reader]. *)
type ('a, 'done_, 'err) step =
  | Step_elem of 'a
  | Step_end of 'done_
  | Step_fail of 'err

type ('a, 'done_, 'err) cursor = {
  next : unit -> ('a, 'done_, 'err) step;
  release : unit -> unit;
}

(* ---- source and map: Pull is clean and direct here ---------------------- *)

let source (xs : 'a list) (done_ : 'done_) : ('a, 'done_, 'err) cursor =
  let state = ref xs in
  {
    release = (fun () -> ());
    next =
      (fun () ->
        match !state with
        | [] -> Step_end done_
        | x :: rest ->
            state := rest;
            Step_elem x);
  }

let map (f : 'a -> 'b) (c : ('a, 'd, 'err) cursor) : ('b, 'd, 'err) cursor =
  {
    release = c.release;
    next =
      (fun () ->
        match c.next () with
        | Step_elem a -> Step_elem (f a)
        | Step_end d -> Step_end d
        | Step_fail e -> Step_fail e);
  }

(* ---- the transducer: pull-from-upstream under another name --------------- *)

(* To split lines, the transducer must pull from an upstream cursor of string
   chunks. It holds:
     - a reference to the upstream cursor
     - its own leftover carry
     - its own pending output buffer (lines found but not yet emitted)
   and on upstream [Step_end] it must emit the leftover as its OWN terminal
   value. This is exactly a Channel's read/emit/done, expressed with a cursor. *)
let split_lines (up : (string, 'up_done, 'err) cursor)
  : (string, string, 'err) cursor =
  let carry = ref "" in
  let pending = ref [] in (* lines completed, not yet handed out, reversed *)
  let upstream_terminal = ref None in
  let pending_error = ref (None : 'err option) in
  let fill () =
    if !upstream_terminal <> None || !pending_error <> None then ()
    else
      match up.next () with
      | Step_elem chunk ->
          let buf = !carry ^ chunk in
          let len = String.length buf in
          let rec explode start acc i =
            if i = len then (acc, String.sub buf start (len - start))
            else if buf.[i] = '\n' then
              explode (i + 1) (String.sub buf start (i - start) :: acc) (i + 1)
            else explode start acc (i + 1)
          in
          let new_rev, rest = explode 0 [] 0 in
          carry := rest;
          pending := List.rev_append new_rev !pending
      | Step_end _ -> upstream_terminal := Some !carry
      | Step_fail e ->
          (* The leftover [!carry] and the error [e] compete for one terminal
             slot. A Channel separates in_done from in_err natively; a cursor
             must drop one. We stash the leftover implicitly (it is lost) and
             surface the error. *)
          pending_error := Some e
  in
  {
    release = up.release;
    next =
      (fun () ->
        match !pending with
        | line :: rest ->
            pending := rest;
            Step_elem line
        | [] ->
            (let continue = ref true in
             while !continue && !pending = [] && !pending_error = None
                   && !upstream_terminal = None do
               fill ()
             done;
             match (!pending, !pending_error, !upstream_terminal) with
             | line :: rest, _, _ ->
                 pending := rest;
                 Step_elem line
             | _, Some e, _ -> Step_fail e
             | [], _, Some leftover -> Step_end leftover
             | [], None, None -> Step_end ""));
  }

(* ---- demonstration ------------------------------------------------------ *)

let () =
  let up = source [ "a\nb"; "\nc"; "d" ] () in
  let td = split_lines up in
  let rec drain acc =
    match td.next () with
    | Step_elem line -> drain (line :: acc)
    | Step_end terminal -> (List.rev acc, terminal)
    | Step_fail _ -> (List.rev acc, "<failed>")
  in
  let lines, terminal = drain [] in
  Printf.printf "pull split_lines emitted: %s\n" (String.concat " | " lines);
  Printf.printf "pull split_lines terminal leftover: %s\n" terminal

(* ---- what C cost vs B --------------------------------------------------- *)
(* The cursor-based transducer works, but observe what it had to re-introduce
   by hand:
     - a leftover carry                (Channel state)
     - a pending output buffer         (Channel emit queue)
     - upstream_done / upstream_terminal(Channel read/done)
     - a poll loop inside next         (Channel pull driver)
   It also cannot carry BOTH a terminal leftover and a terminal error in the
   same result slot — exactly the 'in_done vs in_err' separation that a
   Channel gives natively. C reaches the same place as B but with hand-rolled
   ad-hoc state instead of a typed read/emit/done protocol. *)
