type ('err, 'a) resource = {
  mutable value : 'a option;
  failures : 'err list ref;
}

let make_portable_refresh resource =
  let (refresh @ portable) value =
    resource.value <- Some value;
    resource.failures := []
  in
  refresh

