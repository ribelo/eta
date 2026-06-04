(** ALPN dispatch state machine.

    This module is deliberately pure. It records the H-D5 first-arrival
    collapse rules without owning sockets, fibers, or h1/h2 connection
    resources. The transport dispatcher supplies those resources around the
    decisions returned here. *)

type protocol : immutable_data = H1 | H2

type pending : immutable_data

type t

type begin_result : immutable_data =
  | Leader of pending
  | Wait of pending
  | Ready of protocol

type resolve_result : immutable_data =
  | Installed of protocol
  | Already_ready of protocol
  | Ignored

type stats : immutable_data = {
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
val stats : t -> stats
