(* Branch A: Supervisor.with_child helper

   This fixture probes whether a `Supervisor.with_child` helper can express
   the WebSocket streaming session without requiring the API reshape that
   Branch C imposes.

   Hypothesis: the helper centralizes the start-child / use-handle /
   cancel-or-await sequence, preserving typed failure flow and cancellation.

   CRITICAL TYPE-SYSTEM OBSERVATION:
   The current Supervisor.scoped uses rank-2 polymorphism to prevent child
   handle escape. Any helper built directly on Supervisor.scoped inherits this
   restriction. For `with_child` to allow handle escape, it must NOT be built
   on Supervisor.scoped — it needs a different runtime mechanism.

   Two possible interpretations of Branch A:

   A1. Built on Supervisor.scoped (handle cannot escape — same as Branch C)
   A2. New primitive using Eio.Switch directly (handle CAN escape)

   The OBJECTIVE.md's proposed API:

   val with_child :
     ('child_result, 'err) Effect.t ->
     (('child_result, 'err) child -> ('a, 'err) Effect.t) ->
     ('a, 'err) Effect.t

   This API has a fundamental mismatch with the WebSocket pattern:
   - WebSocket's child is a reader_loop : unit -> (unit, ws_error) Effect.t
   - The "handle" the caller needs is NOT the child result; it's the queue
     and connection state shared with the child.
   - The `child` handle from Supervisor represents the fiber itself, not the
     shared state.

   Therefore, `with_child` as proposed does NOT solve WebSocket's problem.
   The WebSocket code would still need to construct `t` and share it with the
   child before `with_child` starts — which is possible but awkward.

   A more useful helper for WebSocket would be:

   val start_supervised :
     (unit, 'err) Effect.t ->  (* the background loop *)
     ('a, 'err) Effect.t     (* body that runs while loop is alive *) ->
     ('a, 'err) Effect.t

   But this is just `Supervisor.scoped` with one child. The rank-2 body
   still prevents handle escape.

   CONCLUSION SO FAR: Branch A as specified in OBJECTIVE.md does NOT
   materially improve over Branch C for the WebSocket consumer. The
   fundamental constraint is the same: either the handle escapes (which
   requires a non-supervised primitive like daemon), or the API is
   callback-shaped.
*)

open Eta

module Ws_branch_a = struct
  type message = [ `Text of string | `Binary of bytes ]
  type t = {
    incoming : (message, ws_error) Queue.t;
    write_mutex : Eio.Mutex.t;
  }
  and ws_error = [ `Protocol of string | `Closed of int * string ]

  (* Attempt at Branch A for WebSocket.

     Problem: with_child's callback receives a `child` handle, not the
     WebSocket state `t`. We must construct `t` BEFORE with_child, then
     share it with the child fiber inside. But `t` still cannot escape
     the with_child callback unless we use a mutable cell or ref — which
     is what the current daemon code does implicitly.

     This is MORE awkward than the current daemon approach, not less. *)
  let connect_attempt ~flow url =
    let t_ref = ref None in
    let child_effect =
      Effect.sync (fun () ->
          let t = { incoming = Queue.create (); write_mutex = Eio.Mutex.create () } in
          t_ref := Some t;
          (* reader_loop uses t *))
      |> Effect.bind (fun () -> Effect.unit)  (* stub: reader_loop *)
    in
    Effect.(
      (* Hypothetical with_child: *)
      Supervisor.with_child child_effect (fun _child ->
          match !t_ref with
          | None -> Effect.fail (`Protocol "child did not initialize")
          | Some t ->
              (* User code here — but t_ref is a mutable escape hatch.
                 This is worse than Branch C's clean callback shape. *)
              Effect.pure t))

  (* Even if we fix the initialization ordering, the fundamental issue
     remains: the shared state `t` is not the same as the child fiber.
     The helper `with_child` operates on the child fiber, not the shared
     state that the consumer actually needs.

     For patterns where the child produces a stream of results (like
     WebSocket messages), the consumer needs the queue/channel, not the
     child handle. The child handle is only useful for await/cancel.

     This suggests that Branch A is poorly matched to streaming/session
     consumers. Branch B (Resource.with_session) might be a better fit
     because it centralizes the shared-state lifecycle.
   *)
end
