(* Branch C: WebSocket using existing primitives (Supervisor.scoped)
   
   This fixture demonstrates the API reshape required to express the
   WebSocket streaming session with existing Supervisor.scoped primitives.
   
   Key constraint: Supervisor.scoped uses a rank-2 body. The child handle
   cannot escape the scope. Therefore the public API must be callback-shaped:
   instead of returning a handle, the connection function accepts a callback
   that receives the handle and runs inside the supervised scope.
*)

open Eta

module Ws = struct
  type message = [ `Text of string | `Binary of bytes ]
  type t = {
    incoming : (message, ws_error) Queue.t;
    write_mutex : Eio.Mutex.t;
    (* ... other fields ... *)
  }
  and ws_error = [ `Protocol of string | `Closed of int * string ]

  (* BRANCH C SHAPE: callback-based connection.
     The user's callback runs inside the supervisor scope.
     When the callback returns, the reader child is cancelled. *)
  let with_connection ~flow ~sw:_ url f =
    Effect.(
      Supervisor.scoped
        {
          run =
            (fun sup ->
              let open Supervisor.Scope in
              let* t = lift (sync (fun () ->
                  { incoming = Queue.create (); write_mutex = Eio.Mutex.create () }))
              in
              (* Start reader as supervised child *)
              let* child = start sup (lift (reader_loop t flow)) in
              (* Run user callback with the handle *)
              let* result = lift (f t) in
              (* Cancel reader when user is done *)
              let* () = cancel child in
              pure result);
        })

  let reader_loop _t _flow = Effect.unit  (* stub *)
end

(* Consumer code under Branch C *)
let send_and_receive url =
  Ws.with_connection ~flow:(Obj.magic ()) url (fun t ->
      (* This callback runs inside Supervisor.scoped.
         The handle [t] cannot escape this closure. *)
      let* () = Ws.send_text t "hello" in
      let* msg = Ws.recv t in
      Effect.pure msg)

(* LOC analysis:
   - with_connection implementation: ~15 lines
   - Consumer call site: callback-shaped, ~5 lines
   - The consumer CANNOT write: let* t = Ws.connect url in ...
*)