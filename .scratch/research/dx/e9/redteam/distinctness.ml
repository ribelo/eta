(* Distinctness probe (committed research artifact; not a dune test target).
   Same surface program under Parallel vs Applicative must observably differ:
   Parallel may interleave; Applicative is strict left-to-right with nothing
   forked.

   Runnable sketch (conceptual — uses Eta public surface):

   let mark log name =
     Effect.sync (fun () ->
         log := name :: !log;
         Eio.Fiber.yield ())

   Under open Syntax + open Syntax.Parallel:
     let* () = mark log "L-start"
     and* () = mark log "R-start" in …
     (* both marks can start before either finishes; log may interleave *)

   Under open Syntax + open Syntax.Applicative:
     let* () = mark log "L-start"
     and* () = mark log "R-start" in …
     (* R-start cannot appear until L-start has settled; ordered log *)

   Executable law coverage lives in:
   - test_syntax_parallel_* (Effect.par semantics via Syntax.Parallel)
   - test_syntax_applicative_strict_left_to_right
   - test_syntax_applicative_right_waits_for_left
   Run: nix develop -c bash -c './_build/default/test/core_eio/run.exe test Effect 55-61'
*)

let parallel_shape = {|
let open Eta.Syntax in
let open Eta.Syntax.Parallel in
let* () = mark "L"
and* () = mark "R" in
Effect.pure ()
|}

let applicative_shape = {|
let open Eta.Syntax in
let open Eta.Syntax.Applicative in
let* () = mark "L"
and* () = mark "R" in
Effect.pure ()
|}

let () =
  (* Artifact presence check only; laws are in the core suite. *)
  assert (String.length parallel_shape > 0);
  assert (String.length applicative_shape > 0);
  print_endline "distinctness shapes recorded (see suite for runtime evidence)"
