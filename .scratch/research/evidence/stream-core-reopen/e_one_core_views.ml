(* One core, sealed views: proving the 5 channel parameters do NOT drag behind
   Stream when Stream is a sealed/abstract module.

   The user's point: a module (+ optionally a functor) lets Stream.t be an
   abstract 2-parameter type whose IMPLEMENTATION is a 5-parameter channel,
   without the channel's parameters leaking into the public surface. This file
   proves that by construction:

     - [Channel] is the single concrete core (5 params).
     - [Stream] is SEALED by [STREAM_PUBLIC]: its public type is
       `('a, 'err) t` — abstract, 2 params. The 5-param channel never appears.
     - A bridge [to_channel]/[of_channel] is the ONLY place the channel type
       surfaces, so transducer power stays reachable by name.
     - A realistic Stream pipeline compiles and runs with 2-param inference.

   If this compiles under [STREAM_PUBLIC], the drag is provably avoidable. *)

open Stream_core_reopen_common

(* ---- the single core: a 5-parameter channel ---------------------------- *)
module Channel = struct
  type ('o, 'od, 'i, 'id, 'e) t =
    | Done of 'od
    | Fail of 'e
    | Emit of 'o * ('o, 'od, 'i, 'id, 'e) t
    | Read of
        ('i -> ('o, 'od, 'i, 'id, 'e) t)
        * ('id -> ('o, 'od, 'i, 'id, 'e) t)
        * ('e -> ('o, 'od, 'i, 'id, 'e) t)

  (* A source emits chunks (lists), then finishes with unit. in_* unused. *)
  let rec source_chunks (xs : 'a list list) : ('a list, unit, 'i, 'id, 'e) t =
    match xs with
    | [] -> Done ()
    | c :: rest -> Emit (c, source_chunks rest)

  (* map within chunks (chunked map). *)
  let rec map_chunks (f : 'a -> 'b) (c : ('a list, 'od, 'i, 'id, 'e) t)
    : ('b list, 'od, 'i, 'id, 'e) t =
    match c with
    | Emit (chunk, rest) -> Emit (List.map f chunk, map_chunks f rest)
    | Done d -> Done d
    | Fail e -> Fail e
    | Read (oe, od, of_) ->
        Read ((fun x -> map_chunks f (oe x)),
              (fun d -> map_chunks f (od d)),
              (fun e -> map_chunks f (of_ e)))

  let rec run_fold (f : 'acc -> 'a -> 'acc) (acc : 'acc)
    (c : ('a list, 'od, 'i, 'id, 'e) t) : ('acc * 'od, 'e) result =
    match c with
    | Done d -> Ok (acc, d)
    | Fail e -> Error e
    | Emit (chunk, rest) -> run_fold f (List.fold_left f acc chunk) rest
    | Read _ -> failwith "source must not read"
end

(* ---- the public Stream surface: SEALED, 2 parameters, no drag ---------- *)
(* This module type IS the user-visible .mli. Count the parameters on [t]:
   exactly two: 'a and 'err. The channel is not mentioned anywhere. *)
module type STREAM_PUBLIC = sig
  type ('a, 'err) t
  val source : 'a list list -> ('a, 'err) t
  val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
  val run_fold : ('acc -> 'a -> 'acc) -> 'acc -> ('a, 'err) t -> ('acc, 'err) result
  (* the only bridge to the core; the channel type appears here and nowhere
     else in the public Stream surface. The input side is fixed (a source never
     reads), exactly as ZStream's underlying channel fixes InElem/InErr/InDone
     to Any. *)
  val to_channel : ('a, 'err) t -> ('a list, unit, unit, unit, 'err) Channel.t
  val of_channel : ('a list, unit, unit, unit, 'err) Channel.t -> ('a, 'err) t
end

module Stream : STREAM_PUBLIC = struct
  (* Implementation: Stream IS the channel with out_elem = 'a list (chunked),
     out_done = unit, in_* fixed to unit. Five params live HERE, in the .ml,
     never in the .mli. *)
  type ('a, 'err) t = ('a list, unit, unit, unit, 'err) Channel.t

  let source xs = (Channel.source_chunks xs
    : ('a list, unit, unit, unit, 'err) Channel.t)
  let map f c = Channel.map_chunks f c
  let run_fold f acc c =
    match Channel.run_fold f acc c with
    | Ok (acc, ()) -> Ok acc
    | Error e -> Error e
  let to_channel c = c
  let of_channel c = c
end

(* ---- demonstration: 2-param public surface, no annotations, runs ------- *)
let () =
  (* A Stream built from chunks, mapped, folded. No type annotations; inference
     sees only ('a, 'err) Stream.t. *)
  let s = Stream.source [ [ 1; 2 ]; [ 3; 4; 5 ] ] in
  let s' = Stream.map (fun n -> n * 10) s in
  let result = Stream.run_fold (fun acc x -> x :: acc) [] s' in
  match result with
  | Ok rev -> Printf.printf "stream pipeline: [%s]\n" (String.concat "; " (List.map string_of_int (List.rev rev)))
  | Error _ -> Printf.printf "stream pipeline: failed\n"

(* ---- transducer power is reachable by name via the bridge --------------- *)
(* The 5-param channel is reachable when you need it; the Stream surface does
   not have to know about it. (Full channel-piping transducers are the
   follow-up's job; here we only prove the bridge type-checks.) *)
let _reach_the_core (s : (int, [ `E ]) Stream.t) =
  let c = Stream.to_channel s in
  ignore (c : (int list, unit, unit, unit, [ `E ]) Channel.t);
  let s2 = Stream.of_channel c in
  ignore (s2 : (int, [ `E ]) Stream.t)
