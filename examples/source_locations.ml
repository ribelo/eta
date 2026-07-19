open Eta

type error = [ `Invalid_user of string ]
[@@deriving eta_error]

let require label condition =
  if not condition then failwith ("source locations check failed: " ^ label)

let contains needle haystack =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > hay_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let attr key attrs =
  List.assoc_opt key attrs

let load_user id =
  let span_name = __FUNCTION__ in
  Effect.fn ~error_pp:pp_error ~kind:Tracer.Client
    ~attrs:[ ("component", "accounts"); ("operation", span_name) ]
    __POS__ span_name
    (Effect.sync_result (fun () ->
         if String.equal id "" then Error (`Invalid_user "empty id")
         else Ok (span_name, "user:" ^ id)))

let program =
  let open Syntax in
  let+ span_name, user = load_user "42" in
  (span_name, String.uppercase_ascii user)

let only_span tracer =
  match Tracer.dump tracer with
  | [ span ] -> span
  | spans ->
      failwith
        (Printf.sprintf "source locations check failed: expected 1 span, got %d"
           (List.length spans))

let verify tracer (span_name, result) =
  let span = only_span tracer in
  let loc =
    match attr "loc" span.Tracer.attrs with
    | Some loc -> loc
    | None -> failwith "source locations check failed: missing loc attr"
  in
  require "function name present" (not (String.equal span_name ""));
  require "span name" (String.equal span.name span_name);
  require "client kind" (span.kind = Tracer.Client);
  require "component attr"
    (attr "component" span.attrs = Some "accounts");
  require "operation attr"
    (attr "operation" span.attrs = Some span_name);
  require "loc file" (contains "source_locations.ml" loc);
  require "result" (String.equal result "USER:42");
  Format.printf "source-locations:name=%s loc=%s attrs=%d result=%s@."
    span.name loc (List.length span.attrs) result

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ()
  in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok result -> verify tracer result
  | Exit.Error cause ->
      Format.eprintf "source locations failed: %a@." (Cause.pp pp_error) cause;
      exit 1
