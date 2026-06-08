open Effet

let show_cause cause =
  Format.asprintf "%a" (Cause.pp Format.pp_print_string) cause

let run eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  Runtime.run rt eff

let scoped_body_and_release_fail () =
  let eff =
    Effect.acquire_release
      ~acquire:(Effect.pure ())
      ~release:(fun () -> Effect.fail "Release")
    |> Effect.bind (fun () -> Effect.fail "Body")
    |> Effect.scoped
  in
  match run eff with
  | Exit.Error cause -> show_cause cause
  | Exit.Ok () -> "Ok"

let race_two_failures () =
  match run (Effect.race [ Effect.fail "A"; Effect.fail "B" ]) with
  | Exit.Error cause -> show_cause cause
  | Exit.Ok () -> "Ok"

let () =
  Printf.printf "scoped body+release failure: %s\n"
    (scoped_body_and_release_fail ());
  Printf.printf "race two failures: %s\n" (race_two_failures ())
