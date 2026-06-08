(* Positive: a [once]-mode release callback can be invoked exactly once,
   which is the correct discipline for [Effect.acquire_release]'s
   release function. *)

let () =
  let resource = ref 0 in
  let (release @ once) v =
    resource := v
  in
  release 42;
  if !resource <> 42 then failwith "once-release did not run"
