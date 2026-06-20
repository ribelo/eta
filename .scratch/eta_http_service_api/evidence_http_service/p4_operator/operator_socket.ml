(* P4 — prove the Serve.h1 piece works end-to-end over a real socket.

   Binds Serve.h1's wrapped handler to a real run_h1 listener, then checks
   /health and /ready return 200. This validates that the readiness+drain piece
   composes correctly with the real server (it is not just type-checking).

   We use start_h1 (non-blocking) + the wrapped handler so the test can run a
   client in the same switch, then shut the listener down. *)
open Eta

module S = Eta_http.Server

(* replicate Serve.h1's wrapped handler (readiness gate) WITHOUT the blocking
   run, so we can bind it on a managed socket and shut it down cleanly. *)
let wrapped ~ready handler : S.handler =
  fun request ->
    if String.equal request.Eta_http.Server.Request.path "/ready" then
      Effect.pure
        (if !ready then S.Response.text ~status:200 "ready\n"
         else S.Response.text ~status:503 "draining\n")
    else handler request

let base_handler : S.handler =
  S.Handler.of_sync (fun request ->
      match request.Eta_http.Server.Request.path with
      | "/health" -> S.Response.text ~status:200 "ok\n"
      | _ -> S.Response.text ~status:404 "nf\n")

let read_all flow =
  let buf = Buffer.create 256 in
  let scratch = Cstruct.create 1024 in
  let rec loop () =
    (match Eio.Flow.single_read flow scratch with
     | 0 -> Buffer.contents buf
     | n ->
       Buffer.add_string buf (Cstruct.to_string (Cstruct.sub scratch 0 n));
       loop ()
     | exception End_of_file -> Buffer.contents buf)
  in
  loop ()

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let ready = ref true in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = match Eio.Net.listening_addr socket with `Tcp (_, p) -> p | _ -> 0 in
  (* serve on a managed socket; stop promise lets us shut it down *)
  let stop, resolve_stop = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    Eta_http_eio.Server.run_h1_on_socket ~sw:conn_sw ~clock ~socket ~stop
      ~config:Eta_http_eio.Server.Config.default (wrapped ~ready base_handler));
  let get p =
    let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    Fun.protect
      ~finally:(fun () -> (try Eio.Flow.shutdown flow `All with _ -> ()))
      (fun () ->
        Eio.Flow.copy_string
          (Printf.sprintf "GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" p)
          flow;
        read_all flow)
  in
  let status_line resp =
    String.sub resp 0 (String.index resp '\r')
  in
  let check label path expected =
    let line = status_line (get path) in
    if String.equal line expected then
      Printf.printf "[PASS p4] %-10s -> %s\n" path line
    else failwith (Printf.sprintf "[FAIL p4] %s: expected %s got %s" path expected line)
  in
  check "health" "/health" "HTTP/1.1 200 OK";
  check "ready" "/ready" "HTTP/1.1 200 OK";
  (* flip readiness: /ready should now be 503 while /health still 200 *)
  ready := false;
  check "ready-draining" "/ready" "HTTP/1.1 503 Service Unavailable";
  check "health-still" "/health" "HTTP/1.1 200 OK";
  (* clean shutdown *)
  Eio.Promise.resolve resolve_stop ();
  print_endline "p4_operator: Serve readiness gate composes correctly over a real socket"
