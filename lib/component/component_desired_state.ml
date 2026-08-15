(* Immutable desired-state construction.

   Building a desired-state value performs no loading, admission, effect
   execution, or reconciliation. Every constructed value is immutable through
   the public interface: context specs and trees are persistent lists, and an
   entry pairs one component declaration with one matching configuration
   before hiding that configuration type in the node. *)

module Realm = struct
  type t = {
    uid : int;
    name : string;
  }

  let create ~name () =
    { uid = Component_coeffect.fresh_uid (); name }

  let name t = t.name
  let uid t = t.uid
  let equal a b = Int.equal a.uid b.uid
end

(* The root realm holds every unisolated coeffect key. Two coeffect keys that
   use one realm name resolve independently because the provider index is
   keyed by typed key identity and realm identity together. *)
let root_realm = Realm.create ~name:"root" ()

module Context_spec = struct
  type entry =
    | Isolate : _ Component_coeffect.t * Realm.t -> entry
    | Intercept :
        ('value, 'metadata) Component_coeffect.Interception.t * 'metadata
        -> entry

  (* Entries are kept in application order. A later [isolate] for one coeffect
     key shadows earlier mappings; [intercept] entries fold in order. *)
  type t = entry list

  let empty = []
  let isolate coeffect realm spec = spec @ [ Isolate (coeffect, realm) ]

  let intercept interception metadata spec =
    spec @ [ Intercept (interception, metadata) ]
end

module Entry = struct
  type 'config t = {
    id : Component_entry_id.t;
    component : 'config Component_declaration.t;
    config : 'config;
    enabled : bool;
    context : Context_spec.t;
  }

  let make ~id ~component ~config ~enabled ~context =
    { id; component; config; enabled; context }

  let id t = t.id
end

type packed_entry = Packed_entry : 'config Entry.t -> packed_entry

type node =
  | Component_node of packed_entry
  | Group_node of {
      id : Component_entry_id.t;
      enabled : bool;
      context : Context_spec.t;
      children : node list;
    }

type t = node list

let component entry = Component_node (Packed_entry entry)

let group ~id ~enabled ~context children =
  Group_node { id; enabled; context; children }

let tree nodes = nodes
