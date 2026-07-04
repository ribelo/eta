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
