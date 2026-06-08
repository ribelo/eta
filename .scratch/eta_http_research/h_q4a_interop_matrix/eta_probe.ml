(* Scratch-only eta-http interop probe. Not part of the shipped package. *)

type args = {
  mutable method_ : string;
  mutable headers : (string * string) list;
  mutable body_size : int;
  mutable repeat : int;
  mutable h1_only : bool;
  mutable insecure : bool;
  mutable max_h1_bytes : int;
  mutable read_chunks : int option;
  mutable url : string option;
}

let default_args () =
  {
    method_ = "GET";
    headers = [];
    body_size = 0;
    repeat = 1;
    h1_only = false;
    insecure = false;
    max_h1_bytes = 128 * 1024 * 1024;
    read_chunks = None;
    url = None;
  }

let usage () =
  prerr_endline
    "usage: eta_probe.exe [--method METHOD] [--header 'Name: value'] [--body-size BYTES] [--repeat N] [--read-chunks N] [--h1-only] [--insecure] URL";
  exit 2

let parse_header raw =
  match String.index_opt raw ':' with
  | None -> usage ()
  | Some index ->
      let name = String.sub raw 0 index |> String.trim in
      let value =
        String.sub raw (index + 1) (String.length raw - index - 1) |> String.trim
      in
      (name, value)

let rec parse args index =
  if index >= Array.length Sys.argv then ()
  else
    match Sys.argv.(index) with
    | "--method" when index + 1 < Array.length Sys.argv ->
        args.method_ <- Sys.argv.(index + 1);
        parse args (index + 2)
    | "--header" when index + 1 < Array.length Sys.argv ->
        args.headers <- parse_header Sys.argv.(index + 1) :: args.headers;
        parse args (index + 2)
    | "--body-size" when index + 1 < Array.length Sys.argv ->
        args.body_size <- int_of_string Sys.argv.(index + 1);
        parse args (index + 2)
    | "--repeat" when index + 1 < Array.length Sys.argv ->
        args.repeat <- int_of_string Sys.argv.(index + 1);
        parse args (index + 2)
    | "--max-h1-bytes" when index + 1 < Array.length Sys.argv ->
        args.max_h1_bytes <- int_of_string Sys.argv.(index + 1);
        parse args (index + 2)
    | "--read-chunks" when index + 1 < Array.length Sys.argv ->
        args.read_chunks <- Some (int_of_string Sys.argv.(index + 1));
        parse args (index + 2)
    | "--h1-only" ->
        args.h1_only <- true;
        parse args (index + 1)
    | "--insecure" ->
        args.insecure <- true;
        parse args (index + 1)
    | value when String.length value > 0 && value.[0] = '-' -> usage ()
    | value -> (
        match args.url with
        | Some _ -> usage ()
        | None ->
            args.url <- Some value;
            parse args (index + 1))

let failf fmt = Printf.ksprintf (fun msg -> prerr_endline msg; exit 1) fmt

let authenticator ~insecure =
  if insecure then
    match X509.Authenticator.of_string "none" with
    | Ok make -> make (fun () -> None)
    | Error _ -> failf "eta_probe outcome=error stage=auth detail=%S" "bad authenticator"
  else
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error _ -> failf "eta_probe outcome=error stage=ca detail=%S" "ca-certs authenticator failed"

let request_of_args args url =
  let headers =
    match Http.Core.Header.of_list (List.rev args.headers) with
    | Ok headers -> headers
    | Error kind ->
        failf "eta_probe outcome=error stage=headers detail=%S"
          (Http.Error.kind_name kind)
  in
  let body =
    if args.body_size <= 0 then Http.Request.Empty
    else Http.Request.Fixed [ Bytes.make args.body_size 'x' ]
  in
  Http.Request.make ~headers ~body args.method_ url

let rec drain_body ?limit total chunks body =
  match limit with
  | Some limit when chunks >= limit -> Eta.Effect.pure (total, chunks, false)
  | _ -> (
      Http.Body.Stream.read body
      |> Eta.Effect.bind (function
           | None -> Eta.Effect.pure (total, chunks, true)
           | Some chunk ->
               drain_body ?limit (total + Bytes.length chunk) (chunks + 1)
                 body))

let header name headers =
  Http.Core.Header.get name headers |> Option.value ~default:"<none>"

let one_request rt client args url index =
  let request = request_of_args args url in
  Http.request client request
  |> Eta.Effect.bind (fun (response : Http.Response.t) ->
         drain_body ?limit:args.read_chunks 0 0 response.body
         |> Eta.Effect.bind (fun (body_bytes, chunks, complete) ->
                let print trailers =
                  Printf.printf
                    "eta_probe outcome=ok repeat=%d status=%d body_bytes=%d chunks=%d complete=%b location=%S content_type=%S grpc_status=%S trailer_x=%S\n%!"
                    index response.status body_bytes chunks complete
                    (header "location" response.headers)
                    (header "content-type" response.headers)
                    (header "grpc-status" trailers)
                    (header "x-trailer" trailers)
                in
                if complete then response.trailers () |> Eta.Effect.map print
                else Eta.Effect.sync (fun () -> print Http.Core.Header.empty)))
  |> Eta.Runtime.run rt
  |> function
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      failf "eta_probe outcome=error repeat=%d detail=%S" index
        (Format.asprintf "%a" (Eta.Cause.pp Http.Error.pp) cause)

let run env =
  let args = default_args () in
  parse args 1;
  let url = match args.url with Some url -> url | None -> usage () in
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let authenticator = authenticator ~insecure:args.insecure in
  let client =
    if args.h1_only then
      Http.Client.make_h1 ~sw ~net:(Eio.Stdenv.net env) ~authenticator
        ~max_response_body_bytes:args.max_h1_bytes ()
    else
      Http.Client.make ~sw ~net:(Eio.Stdenv.net env) ~authenticator
        ~max_response_body_bytes:args.max_h1_bytes ()
  in
  for index = 1 to args.repeat do
    one_request rt client args url index
  done;
  if Option.is_none args.read_chunks then
    Http.Client.shutdown client |> Eta.Runtime.run rt |> ignore

let () = Eio_main.run run
