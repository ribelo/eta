open Eta

type domain_error =
  [ `Invalid_id of string
  | `Not_found of string ]

type api_error = [ `Request_rejected of string ]

let parse_id = function
  | "" -> Error (`Invalid_id "empty")
  | id -> Ok id

let load_user = function
  | "missing" -> Error (`Not_found "missing")
  | id -> Ok ("user:" ^ id)

let domain_program raw =
  let open Syntax in
  let* id = Effect.from_result (parse_id raw) in
  Effect.sync (fun () -> load_user id)
  |> Effect.flatten_result

let render_domain_error = function
  | `Invalid_id reason -> "invalid:" ^ reason
  | `Not_found id -> "not-found:" ^ id

let to_api_error err =
  `Request_rejected (render_domain_error err)

let program observed raw =
  domain_program raw
  |> Effect.tap_error (fun err ->
         Effect.sync (fun () ->
             observed := render_domain_error err :: !observed))
  |> Effect.map_error to_api_error

let pp_api_error fmt = function
  | `Request_rejected reason -> Format.fprintf fmt "request-rejected:%s" reason

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let observed = ref [] in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match (Eta_eio.Runtime.run rt (program observed "missing"), !observed) with
  | Exit.Error (Cause.Fail (`Request_rejected reason)), [ observed ] ->
      Format.printf "typed-error:observed=%s api=%s@." observed reason
  | Exit.Error cause, _ ->
      Format.eprintf "typed error boundary failed: %a@." (Cause.pp pp_api_error)
        cause;
      exit 1
  | _ ->
      Format.eprintf "typed error boundary produced unexpected result@.";
      exit 1
