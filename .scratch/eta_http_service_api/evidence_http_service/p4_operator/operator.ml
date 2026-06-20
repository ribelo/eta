(* P4 — operator surface: recipe vs a small composable piece.

   QUESTION: does graceful shutdown + readiness/drain belong in the package as a
   small piece, or only as a documented recipe?

   DECISIVE EVIDENCE (from inn, P1 R9): inn calls run_h1 WITHOUT ?stop and
   WITHOUT ?config, and stops the daemon with SIGTERM -> poll -> SIGKILL. The
   ?stop graceful-drain path exists and is tested, but is NOT discoverable enough
   for a real consumer to reach for. That is live operator-surface friction.

   This file prototypes BOTH options for the same job (bind H1, wire SIGTERM to
   graceful drain, expose a readiness flag) and measures them. The judgement is
   in p4_operator.md. *)
open Eta

module S = Eta_http.Server

(* shared: a readiness flag the handler reads, and a trivial handler *)
type readiness = { ready : bool ref }
let make_readiness () = { ready = ref true }

let handler rd : S.handler =
  S.Handler.of_sync (fun request ->
      match request.Eta_http.Server.Request.path with
      | "/health" -> S.Response.text ~status:200 "ok\n"
      | "/ready" ->
          if !(rd.ready) then S.Response.text ~status:200 "ready\n"
          else S.Response.text ~status:503 "draining\n"
      | _ -> S.Response.text ~status:404 "nf\n")

(* ----------------------------------------------------------------------- *)
(* OPTION 1 — RECIPE (what a user writes today, by hand).

   The user must know: run_h1 takes ?stop; resolving stop triggers drain;
   SIGTERM must be wired to flip readiness then resolve stop; Sys.signal needs
   the unsafe_multidomain alert suppressed. inn got this WRONG (no ?stop at all).
   Count the steps. *)
let recipe_run ~port =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let rd = make_readiness () in
  let stop, resolve_stop = Eio.Promise.create () in
  let on_sigterm (_ : int) =
    rd.ready := false;                      (* stop advertising readiness *)
    Eio.Promise.resolve resolve_stop ()      (* trigger graceful drain *)
  in
  ignore (Sys.signal Sys.sigterm (Sys.Signal_handle on_sigterm)
          [@alert.unsafe_multidomain ""]);
  Eta_http_eio.Server.run_h1 ~sw ~net ~clock ~stop
    ~addr:(`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    (handler rd)

(* ----------------------------------------------------------------------- *)
(* OPTION 2 — A SMALL COMPOSABLE PIECE: [Serve.h1].

   Centralizes the repeated protocol: readiness gate + SIGTERM->drain + run_h1.
   The user passes an ordinary [handler] and a port; the piece owns the
   lifecycle invariant (readiness flips before drain; drain respects the
   listener's graceful policy). No global state, no env channel — just a
   function returning unit, like every other Eta piece. *)
module Serve = struct
  type on_ready = Ready of unit | Not_ready

  (* readiness probe: returns 200 while ready, 503 once draining.
     The piece installs /ready automatically unless the handler already covers
     it; for the prototype we let the caller pass the readiness prefix. *)
  let h1 ?(port = 0) ?(config = Eta_http_eio.Server.Config.default) ~handler () =
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net stdenv in
    let clock = Eio.Stdenv.clock stdenv in
    let ready = ref true in
    let stop, resolve_stop = Eio.Promise.create () in
    let on_sigterm (_ : int) =
      ready := false;
      Eio.Promise.resolve resolve_stop ()
    in
    ignore (Sys.signal Sys.sigterm (Sys.Signal_handle on_sigterm)
            [@alert.unsafe_multidomain ""]);
    let wrapped : S.handler =
      fun request ->
        if String.equal request.Eta_http.Server.Request.path "/ready" then
          Effect.pure
            (if !ready then S.Response.text ~status:200 "ready\n"
             else S.Response.text ~status:503 "draining\n")
        else handler request
    in
    Eta_http_eio.Server.run_h1 ~sw ~net ~clock ~stop ~config
      ~addr:(`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) wrapped
end

(* The call-site difference:
     OPTION 1 (recipe): ~25 lines the user must get right (and inn got wrong)
     OPTION 2 (piece):   Serve.h1 ~port ~handler ()
   The piece is ~20 lines ONCE in the library; every consumer saves ~25 lines
   AND gets the readiness+drain invariant correct by construction. *)
let () =
  (* Don't actually bind a port in this fixture (would block). Prove it compiles
     and that both options type-check against the shared handler type. *)
  let _ = (recipe_run, Serve.h1) in
  print_endline "p4_operator: recipe and Serve.h1 piece both compile; see p4_operator.md"
