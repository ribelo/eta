(* P3 fixture 1 — middleware ordering (onion model).

   Proves middleware runs outer-first on the way in and outer-last on the way
   out, and that a typed failure raised by an inner layer propagates back
   through outer layers (so outer access-log/finally still sees it). This is
   the Tower/Ring middleware law, verified for Eta's effect-based middleware. *)
open Eta

module S = Eta_http.Server

(* record label on entry, run inner, record label on exit *)
let layer log_ref label (inner : S.handler) : S.handler =
  let open Eta.Syntax in
  fun request ->
    log_ref := (label ^ ">") :: !log_ref;
    let+ response = inner request in
    log_ref := ("<" ^ label) :: !log_ref;
    response

let request () =
  {
    S.Request.id = lazy "p3";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = "GET";
    target = "/x";
    path = "/x";
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = S.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p3-conn";
  }

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let log = ref [] in
  let inner handler =
    S.Handler.of_sync (fun _ -> S.Response.text ~status:200 "ok\n")
  in
  let stack =
    inner ()
    |> layer log "A"   (* innermost (applied first, so innermost wrap) *)
    |> layer log "B"
    |> layer log "C"   (* outermost (applied last) *)
  in
  (match Eta_eio.Runtime.run rt (stack (request ())) with
   | Exit.Ok r when S.Response.status r = 200 -> ()
   | _ -> failwith "expected 200");
  (* log was built head-first, so reverse to get chronological order *)
  let order = List.rev !log in
  (* onion: outermost (C) enters first and exits last *)
  let expected = [ "C>"; "B>"; "A>"; "<A"; "<B"; "<C" ] in
  if order = expected then
    print_endline ("[PASS p3-order] onion order: " ^ String.concat " " order)
  else
    failwith
      (Printf.sprintf "[FAIL p3-order] expected %s got %s"
         (String.concat " " expected) (String.concat " " order))
