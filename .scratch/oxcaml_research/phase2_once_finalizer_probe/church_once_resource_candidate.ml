(* Candidate G: represent an effect as a one-shot interpreter function rather
   than as reusable data. This checks whether acquire_release can own a once
   release callback outside a GADT constructor. *)

let pure value () = value

let acquire_release ~(acquire @ once) ~(release @ once) () =
  let value = acquire () in
  ignore (release value ());
  value

let run (effect @ once) = effect ()

let () =
  let released = ref false in
  let (release @ once) _ =
    released := true;
    pure ()
  in
  let value = run (acquire_release ~acquire:(pure 1) ~release) in
  if value <> 1 || not !released then failwith "church resource did not run"
