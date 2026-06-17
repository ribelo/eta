open Eta

module Server = Eta_http.Server

let request path =
  {
    Server.Request.id = lazy ("example:" ^ path);
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = "GET";
    target = path;
    path;
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = Server.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "example-connection";
  }

let health =
  Server.Handler.of_sync (fun request ->
      match request.path with
      | "/health" -> Server.Response.text "ok\n"
      | _ -> Server.Response.text ~status:404 "not found\n")

let users =
  Server.Handler.of_result (fun request ->
      match request.path with
      | "/users/42" -> Ok (Server.Response.text "user 42\n")
      | _ ->
          Error
            (Server.Error.make ~method_:request.method_ ~target:request.target
               (Bad_request { message = "unknown user" })))

let users_with_default_errors =
  Server.Handler.with_default_error_response users

let print_response rt label handler path =
  match Eta_eio.Runtime.run rt (handler (request path)) with
  | Exit.Ok response ->
      Format.printf "%s:%d@." label (Server.Response.status response)
  | Exit.Error cause ->
      Format.eprintf "%s failed: %a@." label (Cause.pp Server.Error.pp) cause;
      exit 1

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  print_response rt "health" health "/health";
  print_response rt "user" users "/users/42";
  print_response rt "user-default-error" users_with_default_errors "/users/13"
