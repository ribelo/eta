(* PQ003 (DIAGNOSTIC, steelman of Type.Id): if we UN-ERASE the frame so it
   carries the runtime's own 'err witness, Type.Id recovers the typed cause
   with ZERO Obj. This proves the safe version is possible — and exposes its
   cost: 'err becomes a viral type parameter on the frame/runtime (today it is
   a *phantom* dropped by Obj.magic in runtime_erasure.ml), and the `catch`
   boundary (where 'err changes) needs a fresh frame at the new error type. *)

type 'e cause = Fail of 'e | Die of exn

(* frame now carries the runtime's OWN per-interpreter witness for 'err *)
type 'err frame = { fail_id : 'err cause Type.Id.t; name : string }

type packed = Packed : 'a Type.Id.t * 'a -> packed
exception Raised of packed

let raise_cause (type err) (frame : err frame) (c : err cause) : 'a =
  raise (Raised (Packed (frame.fail_id, c)))

(* unpack: uses the SAME frame.fail_id -> provably_equal certifies the type,
   zero Obj.obj / Obj.magic. *)
let cause_of_exn (type err) (frame : err frame) (e : exn) : err cause option =
  match e with
  | Raised (Packed (id, v)) -> (
      match Type.Id.provably_equal frame.fail_id id with
      | Some Type.Equal -> Some v   (* v : err cause, safely *)
      | None -> None)
  | _ -> None

(* Model the `catch` boundary: inner err1, handler maps to err2.
   Each interpreter level mints its own witness => fresh frame per error type. *)
let new_frame (type e) name : e frame = { fail_id = Type.Id.make (); name }

let () =
  (* one interpreter at error type [ `E1 ] *)
  let f1 : [ `E1 ] frame = new_frame "inner" in
  let recovered =
    try ignore (raise_cause f1 (Fail `E1) : int); None
    with e -> cause_of_exn f1 e
  in
  (match recovered with
   | Some (Fail `E1) -> print_endline "003 inner recovered typed cause, zero Obj"
   | Some (Die _) -> print_endline "003 FAIL: wrong cause"
   | None -> print_endline "003 FAIL: not recovered");

  (* a DIFFERENT interpreter (outer catch frame) at error type [ `E2 ];
     its witness differs, so it does NOT recapture the inner's exception
     -- this is exactly the per-key isolation Eta relies on. *)
  let f2 : [ `E2 ] frame = new_frame "outer" in
  let isolation =
    try ignore (raise_cause f1 (Fail `E1) : int); "no-raise"
    with e -> (match cause_of_exn f2 e with
               | Some _ -> "LEAKED across frames"
               | None -> "isolated (ok)")
  in
  Printf.printf "003 cross-frame isolation: %s\n" isolation;
  print_endline
    "003 PASS: safe with un-erased frame, BUT 'err is now a real (viral) \
     frame/runtime parameter, not the phantom Obj.magic drops today."
