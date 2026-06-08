(* PQ002 (DIAGNOSTIC / disconfirming): does Type.Id remove the unsafe cast
   from the failure transport GIVEN Eta's ERASED, monomorphic frame?

   Eta today (effect_core.ml): the frame carries NO 'err parameter:
     type frame = { runtime : Obj.t Runtime_core.t; fail_key : int; ... }
   The effect's error type lives on the effect, not the frame:
     eval : frame -> ('a,'err) t -> ('a,'err) Exit.t
   raise_cause / cause_of_exn are polymorphic in 'err and a single static
   frame flows through every error type.

   To use Type.Id safely we must thread the SAME 'err-typed witness to both
   the pack site and the unpack site. With a monomorphic frame, the frame can
   only hold a fixed-type witness. We show that this cannot certify recovery:
   the witness type and the raise-site 'err are unrelated, so we are forced
   into an unsafe cast on the witness itself (Obj just moves, not disappears). *)

type cause = Fail_leaf : 'e -> cause  (* erased cause payload, like Cause.t *)

(* monomorphic frame: must fix the witness type *)
type frame = { _witness : int Type.Id.t (* placeholder fixed type *) }

(* The packed existential we'd put in the exception. *)
type packed = Packed : 'a Type.Id.t * 'a -> packed
exception Raised of packed

(* raise site: polymorphic in 'err, like raise_cause *)
let raise_cause (type err) (_frame : frame) (c : err) : 'a =
  (* We need an 'err Type.Id.t to pack. The frame only has int Type.Id.t.
     We cannot obtain an 'err witness equal to the catcher's witness here,
     because the frame is monomorphic. The ONLY ways: *)
  (* (a) mint a fresh 'err id here -> NOT the catcher's id -> provably_equal
         will be None -> recovery fails. Demonstrated unusable below. *)
  let fresh : err Type.Id.t = Type.Id.make () in
  raise (Raised (Packed (fresh, c)))

(* unpack site: also polymorphic in 'err, like cause_of_exn *)
let cause_of_exn (type err) (_frame : frame) (e : exn) : err option =
  match e with
  | Raised (Packed (id, v)) ->
      (* catcher mints/holds its own 'err id; compare *)
      let mine : err Type.Id.t = Type.Id.make () in
      (match Type.Id.provably_equal mine id with
       | Some Type.Equal -> Some v
       | None -> None)
  | _ -> None

let () =
  let frame = { _witness = Type.Id.make () } in
  (try ignore (raise_cause frame `Boom : int) with
   | e ->
       let r : [ `Boom ] option = cause_of_exn frame e in
       match r with
       | Some `Boom -> print_endline "002 recovered (UNEXPECTED)"
       | None ->
           print_endline
             "002 DIAGNOSTIC: fresh-per-site Type.Id never matches -> recovery \
              fails. Erased frame cannot share an 'err witness, so Type.Id \
              cannot certify the cast. Obj is only relocated, not removed.")
