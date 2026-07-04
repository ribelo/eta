type idle
type pure
type committed
type delivering

type +'state token = Token of int

type state =
  | Idle
  | Pure
  | Committed
  | Delivering

type 'error t = {
  id : int;
  mutable state : state;
  mutable transaction :
    (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t option;
}

let next_id = ref 0

let next_state_id () =
  if !next_id = max_int then
    invalid_arg "Eta_signal_stabilization: id overflow";
  let id = !next_id in
  incr next_id;
  id

let create () =
  { id = next_state_id (); state = Idle; transaction = None }

let state t = t.state

let is_pure t =
  match t.state with
  | Pure -> true
  | Idle | Committed | Delivering -> false

let state_label = function
  | Idle -> "idle"
  | Pure -> "pure"
  | Committed -> "committed"
  | Delivering -> "delivering"

let require_state name expected t =
  if t.state <> expected then
    invalid_arg
      ("Eta_signal_stabilization." ^ name ^ ": expected "
      ^ state_label expected ^ ", got " ^ state_label t.state)

let require_token name t (Token id) =
  if id <> t.id then
    invalid_arg
      ("Eta_signal_stabilization." ^ name
     ^ ": token belongs to another stabilization state")

let require_no_transaction name t =
  match t.transaction with
  | None -> ()
  | Some _ ->
      invalid_arg
        ("Eta_signal_stabilization." ^ name
       ^ ": pure transaction is still active")

let begin_pure t =
  match t.state with
  | Idle ->
      require_no_transaction "begin_pure" t;
      t.state <- Pure;
      t.transaction <- Some (Eta_signal_transaction.begin_pure ());
      Ok (Token t.id)
  | Pure | Committed | Delivering ->
      Error `Reentrant_stabilization

let transaction t = t.transaction

let active_transaction t =
  match t.transaction with
  | Some transaction -> transaction
  | None ->
      invalid_arg
        "Eta_signal_stabilization.active_transaction: no active transaction"

let commit_transaction t =
  require_state "commit_transaction" Pure t;
  match t.transaction with
  | None ->
      invalid_arg
        "Eta_signal_stabilization.commit_transaction: no active transaction"
  | Some transaction -> (
      match Eta_signal_transaction.commit transaction with
      | Error _ as error -> error
      | Ok _ ->
          t.transaction <- None;
          Ok ())

let rollback_transaction t =
  require_state "rollback_transaction" Pure t;
  match t.transaction with
  | None ->
      invalid_arg
        "Eta_signal_stabilization.rollback_transaction: no active transaction"
  | Some transaction ->
      Eta_signal_transaction.rollback transaction;
      t.transaction <- None

let commit_to_committed t token =
  require_token "commit_to_committed" t token;
  require_state "commit_to_committed" Pure t;
  require_no_transaction "commit_to_committed" t;
  t.state <- Committed;
  Token t.id

let collect_to_delivering t token =
  require_token "collect_to_delivering" t token;
  require_state "collect_to_delivering" Committed t;
  t.state <- Delivering;
  Token t.id

let commit_to_delivering t token =
  let committed = commit_to_committed t token in
  collect_to_delivering t committed

let rollback_to_idle t token =
  require_token "rollback_to_idle" t token;
  require_state "rollback_to_idle" Pure t;
  require_no_transaction "rollback_to_idle" t;
  t.state <- Idle;
  Token t.id

let finish_delivering t token =
  require_token "finish_delivering" t token;
  require_state "finish_delivering" Delivering t;
  require_no_transaction "finish_delivering" t;
  t.state <- Idle;
  Token t.id

let finish t =
  require_no_transaction "finish" t;
  match t.state with
  | Idle -> ()
  | Pure | Committed | Delivering -> t.state <- Idle
