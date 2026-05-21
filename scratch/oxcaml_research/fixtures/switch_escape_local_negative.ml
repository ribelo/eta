(* Safety axis: capturing an Eio.Switch.t outside its scope is a
   classic Effet/Eio hazard -- the switch is dead by the time the
   captured closure runs. Today, the runtime detects it dynamically
   (the switch raises). With OxCaml [local], the switch can be pinned
   to its scope at the type level, so capture is rejected at compile
   time.

   Expected: this fixture does NOT compile. *)

let bad () =
  let leaked = ref None in
  let with_scope (body : Eio.Switch.t @ local -> unit) =
    Eio_main.run @@ fun _ ->
    Eio.Switch.run @@ fun sw -> body sw
  in
  with_scope (fun sw -> leaked := Some sw);
  match !leaked with
  | None -> ()
  | Some sw -> Eio.Switch.fail sw (Failure "use after free")

let () = bad ()
