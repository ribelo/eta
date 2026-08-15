(* Desired-state admission: flatten the immutable tree into effective entries
   and validate one complete snapshot before any lifecycle mutation. *)

module Coeffect = Component_coeffect
module Desired = Component_desired_state

type flat_entry = {
  fe_id : Component_entry_id.t;
  fe_packed : Desired.packed_entry;
  fe_enabled : bool;
  fe_specs : Desired.Context_spec.t list; (* outermost to innermost *)
  fe_group_path : Component_entry_id.t list; (* ancestor groups, outermost first *)
  fe_position : int;
}

type flat_group = {
  fg_id : Component_entry_id.t;
  fg_enabled : bool;
  fg_specs : Desired.Context_spec.t list;
  fg_position : int;
}

type node_kind =
  | Group_kind
  | Entry_kind

type flattened = {
  entries : flat_entry list;
  groups : flat_group list;
  kinds : (Component_entry_id.t * node_kind) list;
}

let flatten (tree : Desired.t) : flattened =
  let entries = ref [] in
  let groups = ref [] in
  let kinds = ref [] in
  let position = ref 0 in
  let next_position () =
    let p = !position in
    position := p + 1;
    p
  in
  let rec walk ~enabled ~specs ~group_path node =
    match node with
    | Desired.Component_node (Desired.Packed_entry entry) ->
        let position = next_position () in
        kinds := (entry.id, Entry_kind) :: !kinds;
        entries :=
          {
            fe_id = entry.id;
            fe_packed = Desired.Packed_entry entry;
            fe_enabled = enabled && entry.enabled;
            fe_specs = specs @ [ entry.context ];
            fe_group_path = group_path;
            fe_position = position;
          }
          :: !entries
    | Desired.Group_node { id; enabled = own; context; children } ->
        let position = next_position () in
        let enabled = enabled && own in
        let specs = specs @ [ context ] in
        kinds := (id, Group_kind) :: !kinds;
        groups :=
          { fg_id = id; fg_enabled = enabled; fg_specs = specs; fg_position = position }
          :: !groups;
        List.iter (walk ~enabled ~specs ~group_path:(group_path @ [ id ])) children
  in
  List.iter (walk ~enabled:true ~specs:[] ~group_path:[]) tree;
  {
    entries = List.rev !entries;
    groups = List.rev !groups;
    kinds = List.rev !kinds;
  }

(* Node identifiers must be unique in the complete tree; the first repeated
   identifier in tree order is reported. *)
let validate_unique_ids (tree : Desired.t) =
  let exception Duplicate of Component_entry_id.t in
  let seen = Hashtbl.create 16 in
  let record id =
    if Hashtbl.mem seen id then raise (Duplicate id);
    Hashtbl.replace seen id ()
  in
  let rec walk node =
    match node with
    | Desired.Component_node (Desired.Packed_entry entry) -> record entry.id
    | Desired.Group_node { id; children; _ } ->
        record id;
        List.iter walk children
  in
  match List.iter walk tree with
  | () -> Ok ()
  | exception Duplicate id -> Error id

(* A retained identifier cannot change node kind while its runtime authority
   exists. *)
let validate_kinds ~authorities flattened =
  let exception Kind_changed of Component_entry_id.t in
  let check (id, kind) =
    match List.assoc_opt id authorities with
    | Some existing when not (existing = kind) -> raise (Kind_changed id)
    | _ -> ()
  in
  match List.iter check flattened.kinds with
  | () -> Ok ()
  | exception Kind_changed id -> Error id

(* Effective realm for one coeffect key: the innermost [isolate] mapping along
   the entry's context path shadows every outer mapping; an unisolated key
   resolves in the root realm. *)
let effective_realm specs key_uid =
  let apply current entry =
    match entry with
    | Desired.Context_spec.Isolate (coeffect, realm)
      when Int.equal (Coeffect.uid coeffect) key_uid ->
        Some realm
    | _ -> current
  in
  let current =
    List.fold_left
      (fun current spec -> List.fold_left apply current spec)
      None specs
  in
  match current with
  | Some realm -> realm
  | None -> Desired.root_realm

(* Interception metadata layers in fold order: for each context path position,
   outermost to innermost, the metadata entries for one interceptable coeffect
   in application order. *)
let interception_layers specs key_uid =
  List.concat_map
    (fun spec ->
      List.filter_map
        (fun entry ->
          match entry with
          | Desired.Context_spec.Intercept (interception, metadata)
            when Int.equal
                   (Coeffect.uid (Coeffect.Interception.coeffect interception))
                   key_uid ->
              Some
                (Component_declaration.Declared_metadata (interception, metadata))
          | _ -> None)
        spec)
    specs

type requirement_slot = {
  rs_key : Coeffect.Key.t;
  rs_realm : Desired.Realm.t;
}

let requirement_slots flat =
  let (Desired.Packed_entry entry) = flat.fe_packed in
  let (Component_declaration.Component component) = entry.component in
  Component_declaration.requirement_keys component.requirements
  |> List.map (fun (Coeffect.Key.K coeffect) ->
         let key_uid = Coeffect.uid coeffect in
         { rs_key = Coeffect.Key.K coeffect; rs_realm = effective_realm flat.fe_specs key_uid })

type provision_slot = {
  ps_key : Coeffect.Key.t;
  ps_realm : Desired.Realm.t;
}

let provision_slots flat =
  let (Desired.Packed_entry entry) = flat.fe_packed in
  let (Component_declaration.Component component) = entry.component in
  Component_declaration.provision_keys component.provisions
  |> List.map (fun (Coeffect.Key.K coeffect) ->
         let key_uid = Coeffect.uid coeffect in
         { ps_key = Coeffect.Key.K coeffect; ps_realm = effective_realm flat.fe_specs key_uid })

type duplicate_provider = {
  dp_coeffect : string;
  dp_realm : string;
  dp_entries : Component_entry_id.t list;
}

(* Every effectively enabled provision declaration is checked at admission; a
   missing provider is valid and leaves its consumer waiting. *)
let validate_providers flattened =
  let exception Duplicate of duplicate_provider in
  let table = Hashtbl.create 16 in
  let check flat =
    if flat.fe_enabled then
      List.iter
        (fun { ps_key; ps_realm } ->
          let slot =
            Component_provider_graph.slot
              ~key_uid:(Coeffect.Key.uid ps_key)
              ~realm_uid:(Desired.Realm.uid ps_realm)
          in
          match Hashtbl.find_opt table slot with
          | Some first ->
              raise
                (Duplicate
                   {
                     dp_coeffect = Coeffect.Key.name ps_key;
                     dp_realm = Desired.Realm.name ps_realm;
                     dp_entries = [ first; flat.fe_id ];
                   })
          | None -> Hashtbl.replace table slot flat.fe_id)
        (provision_slots flat)
  in
  match List.iter check flattened.entries with
  | () -> Ok ()
  | exception Duplicate duplicate -> Error duplicate

(* The prospective provider graph is computed from every selected slot; every
   cycle is rejected before lifecycle mutation. A missing provider contributes
   no edge and leaves its consumer waiting. *)
let validate_cycles flattened =
  let enabled =
    List.filter (fun flat -> flat.fe_enabled) flattened.entries
  in
  let providers = Hashtbl.create 16 in
  List.iter
    (fun flat ->
      List.iter
        (fun { ps_key; ps_realm } ->
          let slot =
            Component_provider_graph.slot
              ~key_uid:(Coeffect.Key.uid ps_key)
              ~realm_uid:(Desired.Realm.uid ps_realm)
          in
          Hashtbl.replace providers slot flat.fe_id)
        (provision_slots flat))
    enabled;
  let edges flat =
    requirement_slots flat
    |> List.filter_map (fun { rs_key; rs_realm } ->
           let slot =
             Component_provider_graph.slot
               ~key_uid:(Coeffect.Key.uid rs_key)
               ~realm_uid:(Desired.Realm.uid rs_realm)
           in
           Hashtbl.find_opt providers slot)
    |> List.sort_uniq Component_entry_id.compare
  in
  Component_provider_graph.find_cycle
    ~nodes:(List.map (fun flat -> flat.fe_id) enabled)
    ~edges:(fun id ->
      match List.find_opt (fun flat -> Component_entry_id.equal flat.fe_id id) enabled with
      | Some flat -> edges flat
      | None -> [])
