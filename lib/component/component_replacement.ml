(* Replacement targets, candidates, and batches.

   A replacement target correlates one desired-state entry with the expected
   component-instance incarnation and accepted target revision. A batch is
   stamped with one strictly increasing source revision. *)

module Coeffect = Component_coeffect
module Declaration = Component_declaration
module Desired = Component_desired_state
module Ids = Component_ids

(* Target revisions and instance identities are context-qualified: their
   stamps qualify every target by its context. *)
type 'config target = {
  target_entry : 'config Desired.Entry.t;
  expected_instance : Ids.Instance_id.t;
  expected_target : Ids.Target_revision.t;
}

type packed_target = Packed_target : 'config target -> packed_target

let target ~entry ~expected_instance ~expected_target =
  { target_entry = entry; expected_instance; expected_target }

let pack_target target = Packed_target target

type candidate_error = Component_identity_mismatch of Component_entry_id.t

type candidate =
  | Candidate : {
      target : 'config target;
      component : 'config Declaration.t;
    }
      -> candidate

let family_matches :
    type a b. a Declaration.Family.t -> b Declaration.Family.t -> bool =
 fun left right ->
  Int.equal (Declaration.Family.uid left) (Declaration.Family.uid right)
  &&
  match
    Type.Id.provably_equal left.Declaration.Family.config_id
      right.Declaration.Family.config_id
  with
  | Some Type.Equal -> true
  | None -> false

(* A candidate names a component whose family identity and configuration
   identity must equal its target's. The typed path checks the family at
   runtime; the configuration type is unified at compile time. *)
let candidate ~target ~component =
  let (Declaration.Component current) = target.target_entry.component in
  let (Declaration.Component replacement) = component in
  if family_matches current.family replacement.family then
    Ok (Candidate { target; component })
  else Error (Component_identity_mismatch target.target_entry.id)

let loaded_candidate ~target:(Packed_target target) ~component:(Declaration.Packed component) =
  let (Declaration.Component current) = target.target_entry.component in
  let (Declaration.Component replacement) = component in
  match
    Type.Id.provably_equal current.family.Declaration.Family.config_id
      replacement.family.Declaration.Family.config_id
  with
  | Some Type.Equal ->
      if family_matches current.family replacement.family then
        Ok (Candidate { target; component })
      else Error (Component_identity_mismatch target.target_entry.id)
  | None -> Error (Component_identity_mismatch target.target_entry.id)

type batch_error =
  | Empty_batch
  | Duplicate_entry of Component_entry_id.t

type batch = {
  source_revision : Component_source_revision.t;
  candidates : candidate list;
}

let batch ~source_revision candidates =
  match candidates with
  | [] -> Error Empty_batch
  | _ ->
      let exception Duplicate of Component_entry_id.t in
      let seen = Hashtbl.create 8 in
      let check (Candidate { target; _ }) =
        let id = target.target_entry.id in
        if Hashtbl.mem seen id then raise (Duplicate id);
        Hashtbl.replace seen id ()
      in
      (match List.iter check candidates with
      | () -> Ok { source_revision; candidates }
      | exception Duplicate id -> Error (Duplicate_entry id))
