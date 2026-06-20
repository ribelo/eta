(* P2 — Eio socket test: prove Branch A's compiled handler works end-to-end
   through a real Eta_http_eio.Server.run_h1 listener (a real socket), not just
   handler-only. This satisfies the OBJECTIVE P2 requirement ("at least one Eio
   socket test or a clear reason it is unnecessary").

   It also probes the Branch B runner question: how much ceremony does it take
   to bind a handler to a port and read one response over a socket today? *)
open Eta

module S = Eta_http.Server

let json ?(status = 200) yo =
  let h =
    Eta_http.Core.Header.unsafe_add "content-type" "application/json"
      Eta_http.Core.Header.empty
  in
  S.Response.make ~status ~body:(S.Response.Body.string (Yojson.Safe.to_string yo))
    ~headers:h ()

let store : (int * string) list ref = ref []

let service () : S.handler =
  let t = Branch_a.create () in
  Branch_a.add t "/health"
    (fun _req -> Effect.pure (S.Response.text ~status:200 "ok"));
  Branch_a.add t "/items/{id}"
    (fun req ->
      match Branch_a.Req.param req "id" with
      | Some id_s ->
        Effect.pure
          (json (`Assoc [ ("id", `String id_s); ("name", `String ("widget-" ^ id_s)) ]))
      | None -> Effect.pure (json ~status:400 (`String "missing id")));
  Branch_a.add t ~methods:[ "POST" ] "/items"
    (fun req ->
      let open Eta.Syntax in
      let* body = S.Body.read_all (Branch_a.Req.body req) in
      match Yojson.Safe.from_string (Bytes.to_string body) with
      | `Assoc fields ->
        (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
         | Some (`Int id), Some (`String name) ->
           if List.mem_assoc id !store then
             Effect.pure (S.Response.text ~status:409 "conflict\n")
           else begin
             store := (id, name) :: !store;
             Effect.pure (json ~status:201 (`Assoc [ ("id", `Int id); ("name", `String name) ]))
           end
         | _ -> Effect.pure (json ~status:400 (`String "bad body")))
      | _ -> Effect.pure (json ~status:400 (`String "invalid json")));
  Branch_a.compile t

(* read one full HTTP/1.1 response from a flow (close-delimited) *)
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

let send_recv net sw port raw_request =
  let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  Fun.protect
    ~finally:(fun () -> (try Eio.Flow.shutdown flow `All with _ -> ()))
    (fun () ->
      Eio.Flow.copy_string raw_request flow;
      read_all flow)

let () =
  store := [];
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  (* --- the "runner ceremony" Branch B would simplify --- *)
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> failwith "expected tcp"
  in
  (* bind handler to listener in a fork; the client connects from the main fiber *)
  let ready, resolve_ready = Eio.Promise.create () in
  let stop, resolve_stop = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    Eta_http_eio.Server.run_h1_on_socket ~sw:conn_sw ~clock ~socket ~stop
      ~config:Eta_http_eio.Server.Config.default
      (service ()));
  Eio.Promise.resolve resolve_ready ();
  let get p = Printf.sprintf "GET /%s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" p in
  let post body =
    Printf.sprintf "POST /items HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      (String.length body) body
  in
  let check label raw expected_status_prefix =
    let resp = send_recv net sw port raw in
    if String.starts_with ~prefix:expected_status_prefix resp then
      Printf.printf "[PASS socket] %-26s %s\n" label
        (String.sub resp 0 (String.index resp '\r'))
    else
      failwith (Printf.sprintf "[FAIL socket] %s\n  expected prefix %S\n  got %S"
                  label expected_status_prefix (String.sub resp 0 (min 80 (String.length resp))))
  in
  check "GET /health" (get "health") "HTTP/1.1 200 OK";
  check "GET /items/42" (get "items/42") "HTTP/1.1 200 OK";
  check "POST /items (create)" (post {|{"id":1,"name":"x"}|}) "HTTP/1.1 201 Created";
  check "POST /items (conflict)" (post {|{"id":1,"name":"y"}|}) "HTTP/1.1 409";
  check "GET /nope" (get "nope") "HTTP/1.1 404";
  (* shut the listener down cleanly so the process exits 0 *)
  Eio.Promise.resolve resolve_stop ();
  ignore ready;
  print_endline "p2_socket: all end-to-end assertions passed"
