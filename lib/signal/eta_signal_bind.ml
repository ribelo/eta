type ('source, 'inner, 'scope) snapshot = {
  source_value : 'source option;
  inner : 'inner option;
  inner_scope : 'scope option;
}

type ('inner, 'scope) commit_switch = {
  old_inner : 'inner option;
  old_scope : 'scope option;
  new_inner : 'inner;
}

let empty = { source_value = None; inner = None; inner_scope = None }

let switch ~source_value ~inner ~scope =
  {
    source_value = Some source_value;
    inner = Some inner;
    inner_scope = Some scope;
  }

let source_value snapshot = snapshot.source_value
let inner snapshot = snapshot.inner
let inner_scope snapshot = snapshot.inner_scope

let needs_new_inner ~equal snapshot source_value =
  match snapshot.source_value with
  | None -> true
  | Some previous -> not (equal previous source_value)

let switch_parts snapshot =
  match (snapshot.source_value, snapshot.inner, snapshot.inner_scope) with
  | Some source_value, Some inner, Some scope -> Some (source_value, inner, scope)
  | _ -> None

let commit_switch ~current ~staged =
  match switch_parts staged with
  | Some (_, new_inner, _) ->
      Ok
        {
          old_inner = current.inner;
          old_scope = current.inner_scope;
          new_inner;
        }
  | None -> Error `Invalid_scope

let rollback_switch ~staged =
  match switch_parts staged with
  | Some (_, _, scope) -> Ok scope
  | None -> Error `Invalid_scope

let preflight_switch ~current ~staged =
  match switch_parts staged with
  | Some _ -> Ok current.inner_scope
  | None -> Error `Invalid_scope
