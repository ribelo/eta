type ('id, 'owner, 'node) t = {
  id : 'id;
  owner : 'owner;
  parent : ('id, 'owner, 'node) t option;
  mutable valid : bool;
  mutable nodes : 'node list;
}

let create ~id ~owner ~parent =
  { id; owner; parent; valid = true; nodes = [] }

let id scope = scope.id
let owner scope = scope.owner
let parent scope = scope.parent
let valid scope = scope.valid
let nodes scope = scope.nodes
let add_node scope node = scope.nodes <- node :: scope.nodes

let invalidate scope =
  if scope.valid then (
    scope.valid <- false;
    let nodes = scope.nodes in
    scope.nodes <- [];
    Some nodes)
  else None

let rec is_ancestor ~ancestor scope =
  ancestor == scope
  ||
  match scope.parent with
  | None -> false
  | Some parent -> is_ancestor ~ancestor parent

let rec depth = function
  | None -> 0
  | Some scope -> 1 + depth scope.parent

module type VALIDATION_NODE = sig
  type node_id
  type scope_id
  type owner
  type node

  val node_id : node -> node_id
  val valid : node -> bool
  val scope : node -> (scope_id, owner, node) t option
  val children : node -> node list
end

module Make_validation (Node : VALIDATION_NODE) = struct
  let validate_inner ~scope inner =
    let seen = Hashtbl.create 16 in
    let rec visit node =
      if not (Node.valid node) then Error `Invalid_scope
      else if Hashtbl.mem seen (Node.node_id node) then Ok ()
      else (
        Hashtbl.add seen (Node.node_id node) ();
        match Node.scope node with
        | Some node_scope
          when (not (valid node_scope))
               || not (is_ancestor ~ancestor:node_scope scope) ->
            Error `Invalid_scope
        | None | Some _ -> visit_children (Node.children node))
    and visit_children = function
      | [] -> Ok ()
      | node :: nodes -> (
          match visit node with
          | Ok () -> visit_children nodes
          | Error _ as error -> error)
    in
    visit inner
end
