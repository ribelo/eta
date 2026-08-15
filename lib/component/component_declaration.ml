(* Typed component declarations: requirement and provision schemas, component
   families, and the existential component declaration.

   Schema keys are checked by [make] without running any caller callback.
   Requirement, provision, and activation-error types become existential after
   [make]; only the configuration type parameter remains. *)

open Eta
module Coeffect = Component_coeffect

type 'input requirement =
  | Req_none : unit requirement
  | Req_one : 'value Coeffect.t -> 'value requirement
  | Req_intercepted :
      ('value, 'metadata) Coeffect.Interception.t * 'metadata
      -> 'value requirement
  | Req_both : 'left requirement * 'right requirement -> ('left * 'right) requirement
  | Req_map : ('input -> 'output) * 'input requirement -> 'output requirement

type 'output provision =
  | Prov_none : unit provision
  | Prov_one : 'value Coeffect.t -> 'value provision
  | Prov_both : 'left provision * 'right provision -> ('left * 'right) provision
  | Prov_contramap : ('output -> 'staged) * 'staged provision -> 'output provision

module Requirement = struct
  type 'input t = 'input requirement

  let none = Req_none
  let one coeffect = Req_one coeffect
  let intercepted interception ~metadata = Req_intercepted (interception, metadata)
  let both left right = Req_both (left, right)
  let map f requirement = Req_map (f, requirement)
end

module Provision = struct
  type 'output t = 'output provision

  let none = Prov_none
  let one coeffect = Prov_one coeffect
  let both left right = Prov_both (left, right)
  let contramap f provision = Prov_contramap (f, provision)
end

(* Keys in declaration order. *)
let rec requirement_keys : type a. a requirement -> Coeffect.Key.t list =
  function
  | Req_none -> []
  | Req_one coeffect -> [ Coeffect.Key.K coeffect ]
  | Req_intercepted (interception, _) ->
      [ Coeffect.Key.K (Coeffect.Interception.coeffect interception) ]
  | Req_both (left, right) -> requirement_keys left @ requirement_keys right
  | Req_map (_, requirement) -> requirement_keys requirement

let rec provision_keys : type a. a provision -> Coeffect.Key.t list = function
  | Prov_none -> []
  | Prov_one coeffect -> [ Coeffect.Key.K coeffect ]
  | Prov_both (left, right) -> provision_keys left @ provision_keys right
  | Prov_contramap (_, provision) -> provision_keys provision

(* Component-declared interception metadata, in declaration order. *)
type declared_metadata =
  | Declared_metadata :
      ('value, 'metadata) Coeffect.Interception.t * 'metadata
      -> declared_metadata

let rec requirement_metadata : type a. a requirement -> declared_metadata list =
  function
  | Req_none -> []
  | Req_one _ -> []
  | Req_intercepted (interception, metadata) ->
      [ Declared_metadata (interception, metadata) ]
  | Req_both (left, right) ->
      requirement_metadata left @ requirement_metadata right
  | Req_map (_, requirement) -> requirement_metadata requirement

(* Per-generation interception slot: the runtime-owned mutable snapshot a
   wrapped coeffect value samples at each operation entry. *)
type interception_slot =
  | Slot : {
      interception : ('value, 'metadata) Coeffect.Interception.t;
      merged : 'metadata Mutable_ref.t;
    }
      -> interception_slot

let slot_uid (Slot { interception; _ }) =
  Coeffect.uid (Coeffect.Interception.coeffect interception)

(* Requirement resolution runs inside a fresh activation generation: a raising
   [map] callback or interception wrapper construction is captured by the
   surrounding scope as [Cause.Die] for that generation. *)
let missing_required_binding = Failure "eta_component: required binding missing"

let rec resolve : type a. a requirement -> Coeffect.binding list -> interception_slot list -> a =
 fun requirement bindings slots ->
  match requirement with
  | Req_none -> ()
  | Req_one coeffect -> (
      match List.find_map (Coeffect.lookup coeffect) bindings with
      | Some value -> value
      | None -> raise missing_required_binding)
  | Req_intercepted (interception, _) ->
      let uid = Coeffect.uid (Coeffect.Interception.coeffect interception) in
      let (Slot slot) =
        match List.find (fun slot -> Int.equal (slot_uid slot) uid) slots with
        | slot -> slot
        | exception Not_found -> raise missing_required_binding
      in
      (match
         Type.Id.provably_equal
           (Coeffect.Interception.metadata_id interception)
           (Coeffect.Interception.metadata_id slot.interception)
       with
      | None -> raise missing_required_binding
      | Some Type.Equal -> (
          match
            List.find_map
              (Coeffect.lookup (Coeffect.Interception.coeffect interception))
              bindings
          with
          | None -> raise missing_required_binding
          | Some value ->
              Coeffect.Interception.wrap interception
                ~sample:(fun () -> Mutable_ref.get slot.merged)
                value))
  | Req_both (left, right) ->
      (resolve left bindings slots, resolve right bindings slots)
  | Req_map (f, requirement) -> f (resolve requirement bindings slots)

(* Provision staging extracts the complete declared binding set from the
   activation result. A raising [contramap] callback is captured as
   [Cause.Die] for the generation and publishes nothing. *)
let rec stage : type a. a provision -> a -> Coeffect.binding list =
 fun provision value ->
  match provision with
  | Prov_none -> []
  | Prov_one coeffect -> [ Coeffect.binding coeffect value ]
  | Prov_both (left, right) ->
      let left_value, right_value = value in
      stage left left_value @ stage right right_value
  | Prov_contramap (f, provision) -> stage provision (f value)

type declaration_error =
  | Duplicate_requirement of string
  | Duplicate_provision of string
  | Self_dependency of string

let pp_declaration_error fmt = function
  | Duplicate_requirement name ->
      Format.fprintf fmt "duplicate requirement for coeffect %s" name
  | Duplicate_provision name ->
      Format.fprintf fmt "duplicate provision for coeffect %s" name
  | Self_dependency name ->
      Format.fprintf fmt "component requires and provides coeffect %s" name

module Family = struct
  type 'config t = {
    uid : int;
    name : string;
    module_locator : string;
    config_id : 'config Type.Id.t;
  }

  let create ~name ~module_locator () =
    {
      uid = Component_coeffect.fresh_uid ();
      name;
      module_locator;
      config_id = Type.Id.make ();
    }

  let name t = t.name
  let module_locator t = t.module_locator
  let uid t = t.uid
end

type 'config t =
  | Component : {
      uid : int;
      family : 'config Family.t;
      config_equal : 'config -> 'config -> bool;
      requirements : 'requirements requirement;
      provisions : 'provisions provision;
      pp_error : Format.formatter -> 'error -> unit;
      activate :
        'config ->
        'requirements ->
        Component_activation.t ->
        ('provisions, 'error) Effect.t;
    }
      -> 'config t

type packed = Packed : 'config t -> packed

(* Schema-key checking runs no caller callback: [Key.equal] compares allocated
   integer identities only. The first error in declaration order wins:
   requirement keys in schema order, then provision keys in schema order,
   where a provision key already required is a self-dependency. *)
let check_schema_keys requirements provisions =
  let rec check_duplicates seen = function
    | [] -> None
    | key :: rest ->
        if List.exists (Coeffect.Key.equal key) seen then
          Some (Coeffect.Key.name key)
        else check_duplicates (key :: seen) rest
  in
  let required = requirement_keys requirements in
  match check_duplicates [] required with
  | Some name -> Some (Duplicate_requirement name)
  | None ->
      let provided = provision_keys provisions in
      let rec check_provisions seen = function
        | [] -> None
        | key :: rest ->
            if List.exists (Coeffect.Key.equal key) seen then
              Some (Duplicate_provision (Coeffect.Key.name key))
            else if List.exists (Coeffect.Key.equal key) required then
              Some (Self_dependency (Coeffect.Key.name key))
            else check_provisions (key :: seen) rest
      in
      check_provisions [] provided

let make ~family ~config_equal ~requirements ~provisions ~pp_error ~activate =
  match check_schema_keys requirements provisions with
  | Some error -> Error error
  | None ->
      Ok
        (Component
           {
             uid = Component_coeffect.fresh_uid ();
             family;
             config_equal;
             requirements;
             provisions;
             pp_error;
             activate;
           })

let family (Component component) = component.family
let uid (Component component) = component.uid
let pack component = Packed component
