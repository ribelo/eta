open Eta

module Refreshable = Eta_cache.Refreshable

type config = {
  version : int;
  endpoint : string;
}

type error = [ `Reload_failed of string ] [@@deriving eta_error]

let render_config config =
  Printf.sprintf "v%d:%s" config.version config.endpoint

let render_error = function
  | `Reload_failed reason -> "reload-failed:" ^ reason

let load source =
  Eta_observability.named ~error_pp:pp_error "manual.config.load"
    (Effect.sync_result (fun () ->
         match !source with
         | [] -> Error (`Reload_failed "empty source")
         | result :: rest ->
             source := rest;
             result))

let refresh_catching refreshable =
  Refreshable.refresh refreshable
  |> Effect.to_result
  |> Effect.map (function Ok () -> None | Error err -> Some err)

let program source =
  let open Syntax in
  let* refreshable = Refreshable.manual (load source) in
  let* initial = Refreshable.get refreshable in
  let* () = Refreshable.refresh refreshable in
  let* refreshed = Refreshable.get refreshable in
  let* failed = refresh_catching refreshable in
  let* after_failed = Refreshable.get refreshable in
  let+ recorded = Refreshable.failures refreshable in
  (initial, refreshed, failed, after_failed, recorded)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let source =
    ref
      [
        Ok { version = 1; endpoint = "primary" };
        Ok { version = 2; endpoint = "secondary" };
        Error (`Reload_failed "operator rejected reload");
      ]
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program source) with
  | Exit.Ok (initial, refreshed, failed, after_failed, recorded) -> (
      match (refreshed.version, failed, after_failed.version, recorded) with
      | 2, Some (`Reload_failed _ as err), 2, [] ->
          Format.printf
            "manual-resource:initial=%s refreshed=%s after-failure=%s \
             failure=%s recorded=%d@."
            (render_config initial) (render_config refreshed)
            (render_config after_failed) (render_error err)
            (List.length recorded)
      | _ ->
          Format.eprintf "manual resource produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "manual resource failed: %a@." (Cause.pp pp_error) cause;
      exit 1
