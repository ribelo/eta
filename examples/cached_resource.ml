open Eta

module Refreshable = Eta_cache.Refreshable

type config = {
  version : int;
  endpoint : string;
}

type error = [ `Refresh_failed of string ] [@@deriving eta_error]

let render_config config =
  Printf.sprintf "v%d:%s" config.version config.endpoint

let render_error = function
  | `Refresh_failed reason -> "refresh-failed:" ^ reason

let load source =
  Effect.named ~error_pp:pp_error "config.load"
    (Effect.sync_result (fun () ->
         match !source with
         | [] -> Ok { version = 999; endpoint = "fallback" }
         | result :: rest ->
             source := rest;
             result))

let schedule =
  Schedule.both (Schedule.recurs 2) (Schedule.spaced (Duration.ms 20))

let use refreshable =
  let open Syntax in
  let* initial = Refreshable.get refreshable in
  let* () = Effect.delay (Duration.ms 30) Effect.unit in
  let* after_failed_refresh = Refreshable.get refreshable in
  let* failures = Refreshable.failures refreshable in
  let* () = Effect.delay (Duration.ms 30) Effect.unit in
  let+ final = Refreshable.get refreshable in
  (initial, after_failed_refresh, final, failures)

let program source =
  let open Syntax in
  let@ refreshable = Refreshable.with_auto ~load:(load source) ~schedule in
  use refreshable

let program_with_alerts observed source =
  let open Syntax in
  let@ refreshable =
    Refreshable.with_auto_on_refresh_error
      ~on_refresh_error:(fun err -> observed := render_error err :: !observed)
      ~load:(load source) ~schedule
  in
  use refreshable

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let source =
    ref
      [
        Ok { version = 1; endpoint = "primary" };
        Error (`Refresh_failed "provider unavailable");
        Ok { version = 2; endpoint = "secondary" };
      ]
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program source) with
  | Exit.Ok (initial, after_failed_refresh, final, failures) -> (
      match (after_failed_refresh.version, final.version, failures) with
      | 1, 2, [ Cause.Fail (`Refresh_failed _) ] ->
          Format.printf
            "cached-resource:canonical initial=%s after-failure=%s final=%s \
             failures=%d@."
            (render_config initial)
            (render_config after_failed_refresh)
            (render_config final)
            (List.length failures)
      | _ ->
          Format.eprintf "cached resource produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "cached resource failed: %a@." (Cause.pp pp_error) cause;
      exit 1
