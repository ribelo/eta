(* Safety axis: OxCaml [once] mode mechanically forbids calling a release
   callback more than once. Effet's [Effect.acquire_release] takes a
   release function which the runtime must invoke exactly once on the
   acquired value. Today this is a runtime/audit invariant. With
   [once], the type system makes "release runs at most once" a static
   property of the function itself.

   Expected: the function annotated with [once] cannot be invoked
   twice -- this fixture does NOT compile. *)

let bad () =
  let resource = ref 0 in
  let (release @ once) v =
    resource := v;
    Printf.printf "released %d\n" v
  in
  release 1;
  release 2

let () = bad ()
