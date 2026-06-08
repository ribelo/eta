type ('err, 'a) resource = {
  mutable value : 'a option;
  failures : 'err list ref;
}

let refresh resource value =
  resource.value <- Some value;
  resource.failures := []

let smoke () =
  let resource = { value = None; failures = ref [ `Old ] } in
  refresh resource 42;
  match resource.value, !(resource.failures) with
  | Some 42, [] -> ()
  | _ -> failwith "same-domain resource did not refresh"

let () = smoke ()

