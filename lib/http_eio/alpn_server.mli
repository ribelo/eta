(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Server-side ALPN dispatch helpers. *)

type unsupported = { protocol : string }

val dispatch :
  close:(unit -> unit) ->
  use_h1:(unit -> 'a) ->
  use_h2:(unit -> 'a) ->
  string option ->
  ('a, unsupported) result
(** Dispatch a negotiated ALPN value to a server protocol branch.

    [None] and ["http/1.1"] route to H1, ["h2"] routes to H2. Unsupported
    protocols close the underlying transport and return [Error]. *)
