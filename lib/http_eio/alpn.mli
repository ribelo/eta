(** ALPN dispatch state machine.

    This module is deliberately pure. It records the H-D5 first-arrival
    collapse rules without owning sockets, fibers, or h1/h2 connection
    resources. The transport dispatcher supplies those resources around the
    decisions returned here. *)

type protocol = H1 | H2

type pending

type t

type begin_result =
  | Leader of pending
  | Wait of pending
  | Ready of protocol

type resolve_result =
  | Installed of protocol
  | Already_ready of protocol
  | Ignored

type stats = {
  leaders : int;
  waiters : int;
  redundant_cancelled : int;
  h1_resolved : int;
  h2_resolved : int;
}

val create : unit -> t
val pending_id : pending -> int
val begin_request : t -> begin_result
val resolve : t -> pending -> protocol -> resolve_result
val cancel : t -> pending -> unit
val protocol_of_alpn : string option -> (protocol, string) result
(** Decode a negotiated ALPN protocol value.

    [None] is not itself a protocol. Fallback behavior for clients or mixed
    servers belongs in the dispatch policy. *)
val stats : t -> stats
