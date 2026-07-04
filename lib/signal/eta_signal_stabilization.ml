type idle
type pure
type delivering

type +'state token = Token

type state =
  | Idle
  | Pure
  | Delivering

type t = { mutable state : state }

let create () = { state = Idle }
let state t = t.state

let is_pure t =
  match t.state with
  | Pure -> true
  | Idle | Delivering -> false

let state_label = function
  | Idle -> "idle"
  | Pure -> "pure"
  | Delivering -> "delivering"

let require_state name expected t =
  if t.state <> expected then
    invalid_arg
      ("Eta_signal_stabilization." ^ name ^ ": expected "
      ^ state_label expected ^ ", got " ^ state_label t.state)

let begin_pure t =
  match t.state with
  | Idle ->
      t.state <- Pure;
      Ok Token
  | Pure | Delivering ->
      Error `Reentrant_stabilization

let commit_to_delivering t Token =
  require_state "commit_to_delivering" Pure t;
  t.state <- Delivering;
  Token

let rollback_to_idle t Token =
  require_state "rollback_to_idle" Pure t;
  t.state <- Idle;
  Token

let finish t =
  match t.state with
  | Idle -> ()
  | Pure | Delivering -> t.state <- Idle
