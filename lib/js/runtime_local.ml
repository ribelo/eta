type 'a key = { id : int }
type table = (int, Obj.t) Hashtbl.t

let next_id = ref 0

let create () =
  let id = !next_id in
  incr next_id;
  { id }

let id key = key.id
let create_table () = Hashtbl.create 8
let copy_table table = Hashtbl.copy table

let get table key =
  match Hashtbl.find_opt table key.id with
  | None -> None
  | Some value -> Some (Obj.obj value)

let set table key value = Hashtbl.replace table key.id (Obj.repr value)
let remove table key = Hashtbl.remove table key.id

let with_binding table key value f =
  let previous = Hashtbl.find_opt table key.id in
  set table key value;
  Fun.protect f ~finally:(fun () ->
      match previous with
      | None -> remove table key
      | Some value -> Hashtbl.replace table key.id value)
