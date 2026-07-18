open Eta

type error =
  [ `Body_failed
  | `Cleanup_failed ]

let render_error = function
  | `Body_failed -> "body-failed"
  | `Cleanup_failed -> "cleanup-failed"

let pp_error fmt err =
  Format.pp_print_string fmt (render_error err)

let require label condition =
  if not condition then failwith ("finally cleanup check failed: " ^ label)

let mark seen label =
  Effect.sync (fun () -> seen := label :: !seen)

let success seen =
  Effect.pure "ok" |> Effect.finally (mark seen "success-cleanup")

let typed_failure seen =
  Effect.fail `Body_failed |> Effect.finally (mark seen "failure-cleanup")

let cleanup_failure =
  Effect.with_error_pp pp_error
    (Effect.fail `Body_failed |> Effect.finally (Effect.fail `Cleanup_failed))

let cancellation seen =
  Effect.race
    [
      Effect.delay (Duration.ms 1_000) (Effect.pure "slow")
      |> Effect.finally (mark seen "cancel-cleanup");
      Effect.pure "fast";
    ]

let has label seen =
  List.exists (String.equal label) !seen

let verify success_exit failure_exit suppressed_exit cancel_exit seen =
  let success_value =
    match success_exit with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Format.eprintf "unexpected success exit: %a@." (Cause.pp pp_error) cause;
        exit 1
  in
  let failure =
    match failure_exit with
    | Exit.Error (Cause.Fail `Body_failed) -> "body-failed"
    | Exit.Error cause ->
        Format.eprintf "unexpected failure exit: %a@." (Cause.pp pp_error) cause;
        exit 1
    | Exit.Ok _ -> failwith "finally cleanup check failed: expected failure"
  in
  let suppressed =
    match suppressed_exit with
    | Exit.Error
        (Cause.Suppressed
          {
            primary = Cause.Fail `Body_failed;
            finalizer = Cause.Finalizer.Fail "cleanup-failed";
          }) ->
        "suppressed"
    | Exit.Error cause ->
        Format.eprintf "unexpected suppressed exit: %a@." (Cause.pp pp_error)
          cause;
        exit 1
    | Exit.Ok _ -> failwith "finally cleanup check failed: expected suppressed"
  in
  let cancel_value =
    match cancel_exit with
    | Exit.Ok value -> value
    | Exit.Error cause ->
        Format.eprintf "unexpected cancel exit: %a@." (Cause.pp pp_error) cause;
        exit 1
  in
  require "success cleanup" (has "success-cleanup" seen);
  require "failure cleanup" (has "failure-cleanup" seen);
  require "cancel cleanup" (has "cancel-cleanup" seen);
  Format.printf
    "finally-cleanup:success=%s failure=%s cleanup=%s cancel=%s marks=%s@."
    success_value failure suppressed cancel_value
    (String.concat "," (List.rev !seen))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let seen = ref [] in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let success_exit = Eta_eio.Runtime.run rt (success seen) in
  let failure_exit = Eta_eio.Runtime.run rt (typed_failure seen) in
  let suppressed_exit = Eta_eio.Runtime.run rt cleanup_failure in
  let cancel_exit = Eta_eio.Runtime.run rt (cancellation seen) in
  verify success_exit failure_exit suppressed_exit cancel_exit seen
