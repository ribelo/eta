type ('source, 'inner, 'scope) snapshot = {
  source_value : 'source option;
  inner : 'inner option;
  inner_scope : 'scope option;
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
