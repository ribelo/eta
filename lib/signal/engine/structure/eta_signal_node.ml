type state =
  | Live
  | Invalid

type t = { mutable state : state }

let create () = { state = Live }
let is_live t = t.state = Live

let invalidate t =
  match t.state with
  | Invalid -> false
  | Live ->
      t.state <- Invalid;
      true
