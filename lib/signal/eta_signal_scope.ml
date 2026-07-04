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

type ('id, 'owner, 'node) context = {
  mutable current : ('id, 'owner, 'node) t option;
}

let create_context () = { current = None }
let current context = context.current

let require_valid_current context =
  match context.current with
  | Some scope when valid scope -> Ok scope
  | None | Some _ -> Error `Ambiguous_scope

let with_current context scope f =
  let previous = context.current in
  context.current <- Some scope;
  Fun.protect ~finally:(fun () -> context.current <- previous) f

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

module type INVALIDATION_NODE = sig
  type node_id
  type scope_id
  type owner
  type node

  val node_id : node -> node_id
  val equal_node_id : node_id -> node_id -> bool
  val valid : node -> bool
  val dependents : node -> node list
  val nested_scope : node -> (scope_id, owner, node) t option
end

module Make_invalidation (Node : INVALIDATION_NODE) = struct
  let collect ?exclude_node_id seen collected scope =
    let excluded node =
      match exclude_node_id with
      | None -> false
      | Some id -> Node.equal_node_id (Node.node_id node) id
    in
    let rec visit_scope scope =
      if valid scope then List.iter visit (nodes scope)
    and visit node =
      if
        Node.valid node
        && not (excluded node)
        && not (Hashtbl.mem seen (Node.node_id node))
      then (
        Hashtbl.add seen (Node.node_id node) ();
        collected := node :: !collected;
        List.iter visit (Node.dependents node);
        Option.iter visit_scope (Node.nested_scope node))
    in
    visit_scope scope
end
