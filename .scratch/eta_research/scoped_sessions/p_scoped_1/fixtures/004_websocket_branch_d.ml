(* Branch D: Refactor camelpie/WebSocket alone, no Eta change

   The hypothesis: the friction is consumer-shaped, not library-shaped.
   WebSocket's current API returns a handle from `connect_on_flow`:

   val connect_on_flow : ... -> (t, ws_error) Effect.t

   The reshape under Branch C would be callback-shaped:

   val with_connection : ... -> (t -> ('a, ws_error) Effect.t) -> ('a, ws_error) Effect.t

   Is this reshape genuinely heavy? Let's measure.

   CURRENT API (using daemon):
   ```ocaml
   let* t = Ws.connect_on_flow ~flow url in
   let* () = Ws.send_text t "hello" in
   let* msg = Ws.recv t in
   let* () = Ws.close t in
   Effect.pure msg
   ```
   ~5 lines, linear control flow.

   BRANCH C API (using Supervisor.scoped):
   ```ocaml
   Ws.with_connection ~flow url (fun t ->
     let* () = Ws.send_text t "hello" in
     let* msg = Ws.recv t in
     Effect.pure msg)
   ```
   Also ~5 lines, but the callback nesting changes composition:

   - Cannot use `let*` across connection boundaries:
     ```ocaml
     let* t1 = Ws.connect url1 in
     let* t2 = Ws.connect url2 in  (* ILLEGAL: t1 handle escapes *)
     ...
     ```

   - Must nest callbacks:
     ```ocaml
     Ws.with_connection url1 (fun t1 ->
       Ws.with_connection url2 (fun t2 ->
         ...))
     ```

   - Error handling is trickier: exceptions in the callback are caught by
     Supervisor.scoped, but exceptions OUTSIDE (e.g., between connect and use)
     don't exist because there's no "between".

   For a single WebSocket connection, the reshape adds ~0 LOC but changes
   composability. For multiple connections or connection + other resources,
   the nesting becomes significant (callback pyramid).

   VERDICT FOR WEBSOCKET:
   The reshape is NOT heavy for simple cases but IS heavy for compositional
   cases. However, this is specific to WebSocket's handle-escape design.
   If WebSocket were redesigned to use a callback API (like File.with_file),
   it would be idiomatic OCaml and fit Supervisor.scoped naturally.

   The question is whether OTHER consumers have the same problem.
*)

(* Multi-connection example showing Branch D cost *)

open Eta

module Ws = struct
  type message = [ `Text of string | `Binary of bytes ]
  type t = unit  (* stub *)

  let with_connection _url f = f ()  (* stub *)
  let send_text _t _msg = Effect.unit
  let recv _t = Effect.pure (`Text "hello")
end

(* Branch C: nested callbacks for multiple connections *)
let multi_connection_branch_c url1 url2 =
  Ws.with_connection url1 (fun t1 ->
      Ws.with_connection url2 (fun t2 ->
          let* () = Ws.send_text t1 "hello" in
          let* () = Ws.send_text t2 "world" in
          let* msg1 = Ws.recv t1 in
          let* msg2 = Ws.recv t2 in
          Effect.pure (msg1, msg2)))

(* Current daemon API: flat, composable *)
let multi_connection_daemon url1 url2 =
  let* t1 = Ws.with_connection url1 (fun t -> Effect.pure t) in  (* hack *)
  let* t2 = Ws.with_connection url2 (fun t -> Effect.pure t) in
  let* () = Ws.send_text t1 "hello" in
  let* () = Ws.send_text t2 "world" in
  let* msg1 = Ws.recv t1 in
  let* msg2 = Ws.recv t2 in
  Effect.pure (msg1, msg2)
  (* NOTE: This hack doesn't work because t1/t2 can't escape.
     The daemon API is the only way to get flat composition. *)
