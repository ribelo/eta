(* Branch B: Resource.with_session (session-specific resource pattern)

   Hypothesis: streaming WebSocket is conceptually a resource:
   open -> use -> finish/cancel -> close.
   A helper that names that lifetime and ensures composition with
   Effect.timeout and parent Switch cancellation.

   Proposed API shape:

   val with_session :
     acquire:(unit -> ('session, 'err) Effect.t) ->
     use:('session -> ('a, 'err) Effect.t) ->
     finish:('session -> (unit, 'err) Effect.t) ->
     cancel:('session -> (unit, 'err) Effect.t) ->
     ('a, 'err) Effect.t

   Or more concretely for WebSocket:

   val Ws.with_session :
     ?key:string -> ?headers -> ?protocols ->
     flow -> Url.t ->
     (t -> ('a, ws_error) Effect.t) ->
     ('a, ws_error) Effect.t

   The session helper would:
   1. Open the connection (upgrade handshake)
   2. Start the reader loop as a supervised child
   3. Run the user's callback with the handle
   4. On success: send close frame, drain incoming queue, close flow
   5. On cancellation/timeout: send close frame, cancel reader child, close flow
   6. On child failure: propagate typed failure to parent

   This IS a real protocol centralization:
   - finish-vs-cancel asymmetry (drain on finish, hard cancel on timeout)
   - close fence (ensure flow is closed even if callback raises)
   - typed failure propagation from reader loop to parent
   - observability (the session is a named span with child fiber as sub-span)

   IMPLEMENTATION SKETCH:
*)

open Eta

module Ws_branch_b = struct
  type message = [ `Text of string | `Binary of bytes ]
  type t = {
    incoming : (message, ws_error) Queue.t;
    write_mutex : Eio.Mutex.t;
    flow : Eio.Flow.two_way;
  }
  and ws_error = [ `Protocol of string | `Closed of int * string ]

  let reader_loop t = Effect.unit  (* stub *)

  let send_close_frame t = Effect.unit  (* stub *)

  let close_flow t =
    Effect.sync (fun () ->
        try Eio.Flow.close t.flow with _ -> ())

  let with_session ~flow url f =
    Effect.(
      named "ws.session" (
        sync (fun () ->
            { incoming = Queue.create (); write_mutex = Eio.Mutex.create (); flow })
        |> bind (fun t ->
               Supervisor.scoped
                 {
                   run =
                     (fun sup ->
                       let open Supervisor.Scope in
                       let* child = start sup (lift (reader_loop t)) in
                       (* Run user code inside supervised scope *)
                       let* result = lift (f t) in
                       (* Normal finish: graceful close *)
                       let* () = lift (send_close_frame t) in
                       let* () = cancel child in
                       let* () = lift (close_flow t) in
                       pure result);
                 }
               |> catch (fun err ->
                      (* Failure path: ensure cleanup *)
                      close_flow t |> bind (fun () -> fail err)))))

  (* OBSERVATION: Branch B for WebSocket is essentially a well-written
     recipe using Branch C primitives, but with a NAME that signals the
     protocol (session) and centralized cleanup logic.

     The "protocol" being centralized is:
     1. Start background reader as supervised child
     2. Run user callback
     3. On normal exit: graceful close (send close frame, drain, cancel child)
     4. On failure/timeout: hard cancel (cancel child, close flow)
     5. Typed failure propagation from reader to parent

     The question is: does this protocol generalize beyond WebSocket?
     Let's check the other consumers.
   *)
end
