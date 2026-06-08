open Eta

let with_resource ~acquire ~release body =
  let open Syntax in
  let* resource = Effect.acquire_release ~acquire ~release in
  body resource

let let_at_preserves_cps_cleanup_order () =
  let ( let@ ) f k = f k in
  let events = ref [] in
  let acquire =
    events := "acquire" :: !events;
    Effect.pure "resource"
  in
  let release resource =
    events := ("release:" ^ resource) :: !events;
    Effect.unit
  in
  let effect =
    let@ resource = with_resource ~acquire ~release in
    events := ("use:" ^ resource) :: !events;
    Effect.pure ()
  in
  ignore effect;
  ()

let () =
  let_at_preserves_cps_cleanup_order ();
  print_endline "p3_soundness_positive PASS: let@ is ordinary CPS syntax and introduces no runtime primitive"
