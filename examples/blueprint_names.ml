open Eta

type error = [ `Bad_id of string | `Not_found of string ]

let require label condition =
  if not condition then failwith ("blueprint names check failed: " ^ label)

let parse_id raw =
  if String.equal raw "" then Error (`Bad_id "empty id") else Ok raw

let load_config : (string, error) Effect.t =
  Effect.named "config.load"
    (Effect.sync_result (fun () -> Ok "primary"))

let load_user id : (string, error) Effect.t =
  Effect.named "user.load"
    (Effect.sync_result (fun () ->
         if String.equal id "missing" then Error (`Not_found id)
         else Ok ("user:" ^ id)))

let program raw =
  let open Syntax in
  Effect.named "request.handle"
    (let* config = load_config in
     let* id = Effect.from_result (parse_id raw) in
     let+ user = load_user id in
     config ^ ":" ^ user)

let pp_error fmt = function
  | `Bad_id message -> Format.fprintf fmt "bad-id:%s" message
  | `Not_found id -> Format.fprintf fmt "not-found:%s" id

let has_name expected names =
  List.exists (String.equal expected) names

let verify_blueprint eff =
  let names = Effect.collect_names eff in
  require "top name" (Effect.name eff = Some "request.handle");
  require "request name" (has_name "request.handle" names);
  require "static config name" (has_name "config.load" names);
  require "dynamic continuation omitted" (not (has_name "user.load" names));
  names

let () =
  let eff = program "42" in
  let names = verify_blueprint eff in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok result ->
      Format.printf "blueprint-names:name=%s static=%s result=%s@."
        (Option.value ~default:"<none>" (Effect.name eff))
        (String.concat "," names) result
  | Exit.Error cause ->
      Format.eprintf "blueprint names failed: %a@." (Cause.pp pp_error) cause;
      exit 1
