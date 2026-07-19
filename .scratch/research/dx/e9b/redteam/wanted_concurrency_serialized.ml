(* Red-team (b): a program that WANTED concurrency but used and*.
   Both effects run, in order; no cancellation on failure of the "other"
   sibling because there is no sibling. Residual cost is latency only. *)

open Eta

let log = ref []

let mark name =
  Effect.sync (fun () -> log := name :: !log)

let load name delay_yields =
  let open Syntax in
  let* () = mark (name ^ ":start") in
  let rec yield_n n =
    if n <= 0 then Effect.pure ()
    else
      let* () = Effect.yield in
      yield_n (n - 1)
  in
  let* () = yield_n delay_yields in
  let* () = mark (name ^ ":done") in
  Effect.pure name

(* Author intent: concurrent independent loads.
   Spelling: and* → sequential product (correct values, serialized). *)
let loads () =
  let open Syntax in
  let* left = load "user" 3
  and* right = load "perms" 3 in
  Effect.pure (left, right)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (loads ()) with
  | Exit.Ok ("user", "perms") ->
      let ordered = List.rev !log in
      Format.printf "loads ok; log=%s@." (String.concat " → " ordered);
      let expected =
        [ "user:start"; "user:done"; "perms:start"; "perms:done" ]
      in
      if ordered <> expected then (
        Format.eprintf "expected serialized both-run log@.";
        exit 1);
      Format.printf
        "VERDICT (b): correct-but-serialized; both effects run in order; \
         residual cost is latency only@."
  | Exit.Ok _ ->
      Format.eprintf "unexpected Ok pair@.";
      exit 1
  | Exit.Error cause ->
      Format.eprintf "loads failed: %a@." (Cause.pp Format.pp_print_string) cause;
      exit 1
