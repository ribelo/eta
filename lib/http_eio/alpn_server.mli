(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Server-side ALPN dispatch helpers. *)

type unsupported = { protocol : string }

val dispatch :
  enabled_protocols:Dispatch.enabled_protocols ->
  close:(unit -> unit) ->
  use_h1:(unit -> 'a) ->
  use_h2:(unit -> 'a) ->
  string option ->
  ('a, unsupported) result
(** Dispatch a negotiated ALPN value to a server protocol branch under an
    explicit enabled-protocol policy.

    [None] routes to H1 only when H1 fallback is enabled. ["h2"] routes to H2
    only when H2 is enabled. Unsupported or disabled protocols close the
    underlying transport and return [Error]. *)
