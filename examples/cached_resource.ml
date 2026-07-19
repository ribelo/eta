open Eta

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

let program observed source =
  let open Syntax in
  let* resource =
    Resource.auto ~load:(load source) ~schedule
      ~on_error:(fun err -> observed := render_error err :: !observed)
      ()
  in
  let* initial = Resource.get resource in
  let* () = Effect.delay (Duration.ms 30) Effect.unit in
  let* after_failed_refresh = Resource.get resource in
  let* failures = Resource.failures resource in
  let* () = Effect.delay (Duration.ms 30) Effect.unit in
  let+ final = Resource.get resource in
  (initial, after_failed_refresh, final, failures)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let observed = ref [] in
  let source =
    ref
      [
        Ok { version = 1; endpoint = "primary" };
        Error (`Refresh_failed "provider unavailable");
        Ok { version = 2; endpoint = "secondary" };
      ]
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program observed source) with
  | Exit.Ok (initial, after_failed_refresh, final, failures) -> (
      match
        (after_failed_refresh.version, final.version, failures, !observed)
      with
      | 1, 2, [ Cause.Fail (`Refresh_failed _) ], [ _ ] ->
          Format.printf
            "cached-resource:initial=%s after-failure=%s final=%s failures=%d \
             observed=%d@."
            (render_config initial)
            (render_config after_failed_refresh)
            (render_config final)
            (List.length failures)
            (List.length !observed)
      | _ ->
          Format.eprintf "cached resource produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "cached resource failed: %a@." (Cause.pp pp_error) cause;
      exit 1
