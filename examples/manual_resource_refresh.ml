open Eta

type config = {
  version : int;
  endpoint : string;
}

type error = [ `Reload_failed of string ]

let render_config config =
  Printf.sprintf "v%d:%s" config.version config.endpoint

let render_error = function
  | `Reload_failed reason -> "reload-failed:" ^ reason

let load source =
  Effect.named "manual.config.load"
    (Effect.sync (fun () ->
         match !source with
         | [] -> Error (`Reload_failed "empty source")
         | result :: rest ->
             source := rest;
             result)
     |> Effect.flatten_result)

let refresh_catching resource =
  Resource.refresh resource
  |> Effect.to_result
  |> Effect.map (function Ok () -> None | Error err -> Some err)

let program source =
  let open Syntax in
  let* resource = Resource.manual (load source) in
  let* initial = Resource.get resource in
  let* () = Resource.refresh resource in
  let* refreshed = Resource.get resource in
  let* failed = refresh_catching resource in
  let* after_failed = Resource.get resource in
  let+ recorded = Resource.failures resource in
  (initial, refreshed, failed, after_failed, recorded)

let pp_error fmt err =
  Format.pp_print_string fmt (render_error err)

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
