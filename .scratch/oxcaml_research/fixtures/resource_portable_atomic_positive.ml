open! Portable

type ('err, 'a) resource = {
  value : 'a option Atomic.t;
  failures : 'err list Atomic.t;
}

let make_portable_refresh resource =
  let (refresh @ portable) value =
    Atomic.set resource.value (Some value);
    Atomic.set resource.failures []
  in
  refresh

let smoke () =
  let resource = { value = Atomic.make None; failures = Atomic.make [ `Old ] } in
  let refresh = make_portable_refresh resource in
  refresh 42;
  match Atomic.get resource.value, Atomic.get resource.failures with
  | Some 42, [] -> ()
  | _ -> failwith "portable atomic resource did not refresh"

let () = smoke ()

