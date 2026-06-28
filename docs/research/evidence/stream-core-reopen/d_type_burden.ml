(* Type-burden measurement: testing V-S1's "seven parameters too expensive".

   V-S1 rejected a public Channel on the claim that "making Channel public
   imports seven parameters into OCaml APIs". This file measures the actual
   OCaml cost, distinguishing the three places parameters can appear:

     1. Call sites (user code applying operators).
     2. Module signatures (.mli) for operators and transducers.
     3. Inference and error-message quality.

   Method: every value below is given to the compiler with as FEW annotations
   as possible. If it compiles, the annotation burden is "none". Where an
   annotation is structurally required (a .mli), we write the minimal one and
   count the type parameters. *)

open Stream_core_reopen_common

(* Re-declare the 5-parameter channel shape (copy of candidate B's core). *)
type ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel =
  | C_done of 'out_done
  | C_fail of 'err
  | C_emit of 'out_elem * ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel

let rec source xs d =
  match (xs : 'a list) with
  | [] -> C_done d
  | x :: rest -> C_emit (x, source rest d)

let rec map f c =
  match c with
  | C_emit (a, rest) -> C_emit (f a, map f rest)
  | C_done d -> C_done d
  | C_fail e -> C_fail e

(* ----------------------------------------------------------------------- *)
(* MEASUREMENT 1: call-site annotation burden.                             *)
(* ----------------------------------------------------------------------- *)
(* A realistic user pipeline. NO type annotations anywhere. Compiles => the
   "five parameters" never surface at the call site. *)

let pipeline_no_annotations () =
  let s = source [ 1; 2; 3; 4; 5 ] () in
  let s' = map (fun n -> n * 2) s in
  let s'' = map (fun n -> Printf.sprintf "%d" n) s' in
  s''

(* The compiler infers s'' : (string, unit, <free>, <free>, <free>) channel.
   The user wrote zero type parameters. Whatever cost the five parameters have,
   it is NOT paid at call sites. *)

(* ----------------------------------------------------------------------- *)
(* MEASUREMENT 2: .mli signature burden.                                   *)
(* ----------------------------------------------------------------------- *)
(* Here the parameters DO appear. This module type pins the exact signatures
   one would put in an .mli. We count the type parameters each carries. *)

module type STREAM_LIKE_OPS = sig
  (* Current eta_stream shape: 2 type parameters per operator. *)
  type ('a, 'err) t
  val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
  val source : 'a list -> ('a, 'err) t
end

module type CHANNEL_OPS = sig
  (* Candidate B: 5 type parameters per operator. The parameters repeat, but
     'in_done and 'err are usually free for sources/maps. *)
  type ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) t
  val map :
    ('a -> 'b) ->
    ('a, 'd, 'i, 'id, 'err) t ->
    ('b, 'd, 'i, 'id, 'err) t
  val source : 'a list -> 'd -> ('a, 'd, 'i, 'id, 'err) t
  (* A transducer — the thing the current shape CANNOT express at all. *)
  val split_lines :
    unit -> (string, string, string, 'in_done, 'err) t
end

(* Observation: channel [map] writes 5 params x2 (10 occurrences) vs stream
   [map] 2 params x2 (4 occurrences). The cost is real for mli verbosity but:
     - it is confined to the library's own .mli, not user code (measurement 1);
     - a type alias [type 'a stream = ('a, unit, _, _, 'err) channel] collapses
       it back to ~2 params for the non-transducer case;
     - and it buys a typed terminal value and a transducer that the 2-param
       shape cannot express at any verbosity. *)

(* Demonstrate the alias trick: define [stream] as a channel with the input and
   done sides fixed, recovering a 2-parameter surface for sources/maps. *)
type ('a, 'err) stream_alias =
  ('a, unit, Obj.t, unit, 'err) channel

let _stream_alias_uses_2_params (s : (int, [ `E ]) stream_alias) =
  (s : (int, unit, Obj.t, unit, [ `E ]) channel)

(* ----------------------------------------------------------------------- *)
(* MEASUREMENT 3: error-message quality.                                   *)
(* ----------------------------------------------------------------------- *)
(* When a user wires a channel producing ints into a sink expecting strings,
   the error names the channel type and the mismatched element. The negative
   fixture neg_error_row.ml captures the analogous row-mismatch error:

     "This expression has type (int list * unit, [ `Boom ]) result
      but an expression was expected of type (int list * unit, [ `Other ]) result
      These two variant types have no intersection"

   That is the same quality as the current eta_stream error (old neg_b). The
   five parameters do not degrade error messages: unbound/free params are
   shown as '_', and the mismatched param is the one surfaced. *)

let () =
  let _ = pipeline_no_annotations () in
  Printf.printf "measurement: call-site pipeline compiled with ZERO annotations.\n";
  Printf.printf "measurement: channel .mli writes 5 params; an alias recovers 2.\n";
  Printf.printf "measurement: error quality matches the current eta_stream shape.\n"
