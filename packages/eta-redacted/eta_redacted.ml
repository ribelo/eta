type 'a t = {
  mutable value : 'a option;
  label : string option;
}

let make ?label value = { value = Some value; label }

let value t =
  match t.value with
  | Some value -> value
  | None -> failwith "Redacted.value: wiped"

let wipe_unsafe t =
  let was_present = Option.is_some t.value in
  t.value <- None;
  was_present

let label t = t.label

let pp fmt t =
  match t.label with
  | Some label -> Format.pp_print_string fmt ("<redacted:" ^ label ^ ">")
  | None -> Format.pp_print_string fmt "<redacted>"

let equal eq a b =
  match (a.value, b.value) with
  | Some av, Some bv -> eq av bv
  | _ -> false

let hash h t =
  match t.value with
  | Some value -> h value
  | None -> 0
