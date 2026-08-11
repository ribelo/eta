module Testing : sig
  module Effect_id : sig
    type t
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Commit_index : sig
    type t
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
    val to_int64 : t -> int64
  end

  module Event_position : sig
    type t
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
    val to_int64 : t -> int64
  end

  type settlement =
    | Succeeded
    | Interrupted
    | Failed

  type event =
    | Staged of {
        position : Event_position.t;
        commit : Commit_index.t;
        effects : Effect_id.t list;
      }
    | Started of {
        position : Event_position.t;
        effect : Effect_id.t;
      }
    | Settled of {
        position : Event_position.t;
        effect : Effect_id.t;
        settlement : settlement;
      }
    | Discarded_before_start of {
        position : Event_position.t;
        effect : Effect_id.t;
      }

  type post_commit_effect_observer
end

type observer = Testing.post_commit_effect_observer
type observed_effect

val create : unit -> observer
val claim : observer -> unit
val stage : observer -> int -> observed_effect list
val started : observed_effect -> unit
val settled : observed_effect -> Testing.settlement -> unit
val discarded : observed_effect -> unit
val poll : observer -> Testing.event option
val drain : observer -> Testing.event list
val is_empty : observer -> bool
