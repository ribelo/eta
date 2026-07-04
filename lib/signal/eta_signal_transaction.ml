type id = Id of int

type pure
type committed
type observers

type state =
  | Open
  | Committed
  | Rolled_back

type 'a pending = {
  tx_id : id;
  value : 'a;
}

type 'a staged = {
  mutable current : 'a;
  mutable pending : 'a pending option;
}

type packed_staged = Staged : 'a staged -> packed_staged

type 'error core = {
  id : id;
  mutable state : state;
  mutable staged_cells : packed_staged list;
  mutable preflight_hooks : (unit -> (unit, 'error) result) list;
  mutable commit_hooks : (unit -> unit) list;
  mutable rollback_hooks : (unit -> unit) list;
}

type (+'phase, 'error) t = { core : 'error core }

let next_id = ref 0

let create_staged current = { current; pending = None }
let current staged = staged.current
let set_current staged value = staged.current <- value
let id tx = tx.core.id
let equal_id (Id left) (Id right) = Int.equal left right

let next_transaction_id () =
  if !next_id = max_int then invalid_arg "Eta_signal_transaction: id overflow";
  let id = !next_id in
  incr next_id;
  Id id

let begin_pure () =
  {
    core =
      {
        id = next_transaction_id ();
        state = Open;
        staged_cells = [];
        preflight_hooks = [];
        commit_hooks = [];
        rollback_hooks = [];
      };
  }

let state_label = function
  | Open -> "open"
  | Committed -> "committed"
  | Rolled_back -> "rolled back"

let require_open name tx =
  match tx.core.state with
  | Open -> ()
  | state ->
      invalid_arg
        ("Eta_signal_transaction." ^ name ^ ": transaction is "
       ^ state_label state)

let read tx staged =
  match staged.pending with
  | Some pending when equal_id pending.tx_id tx.core.id -> pending.value
  | Some _ | None -> staged.current

let staged tx staged =
  match staged.pending with
  | Some pending -> equal_id pending.tx_id tx.core.id
  | None -> false

let remember_staged_cell tx staged =
  tx.core.staged_cells <- Staged staged :: tx.core.staged_cells

let stage tx staged value =
  require_open "stage" tx;
  match staged.pending with
  | None ->
      staged.pending <- Some { tx_id = tx.core.id; value };
      remember_staged_cell tx staged
  | Some pending when equal_id pending.tx_id tx.core.id ->
      staged.pending <- Some { pending with value }
  | Some _ ->
      invalid_arg
        "Eta_signal_transaction.stage: staged value belongs to another \
         transaction"

let on_preflight tx hook =
  require_open "on_preflight" tx;
  tx.core.preflight_hooks <- hook :: tx.core.preflight_hooks

let on_commit tx hook =
  require_open "on_commit" tx;
  tx.core.commit_hooks <- hook :: tx.core.commit_hooks

let on_rollback tx hook =
  require_open "on_rollback" tx;
  tx.core.rollback_hooks <- hook :: tx.core.rollback_hooks

let rec run_preflight_hooks = function
  | [] -> Ok ()
  | hook :: hooks -> (
      match hook () with
      | Ok () -> run_preflight_hooks hooks
      | Error _ as error -> error)

let preflight tx =
  require_open "preflight" tx;
  run_preflight_hooks (List.rev tx.core.preflight_hooks)

let commit_staged_cell tx_id (Staged staged) =
  match staged.pending with
  | Some pending when equal_id pending.tx_id tx_id ->
      staged.current <- pending.value;
      staged.pending <- None
  | Some _ | None -> ()

let rollback_staged_cell tx_id (Staged staged) =
  match staged.pending with
  | Some pending when equal_id pending.tx_id tx_id -> staged.pending <- None
  | Some _ | None -> ()

let change_phase tx = { core = tx.core }

let commit tx =
  require_open "commit" tx;
  match preflight tx with
  | Error _ as error -> error
  | Ok () ->
      List.iter (commit_staged_cell tx.core.id) (List.rev tx.core.staged_cells);
      tx.core.staged_cells <- [];
      tx.core.state <- Committed;
      List.iter (fun hook -> hook ()) (List.rev tx.core.commit_hooks);
      tx.core.commit_hooks <- [];
      tx.core.rollback_hooks <- [];
      tx.core.preflight_hooks <- [];
      Ok (change_phase tx)

let rollback tx =
  require_open "rollback" tx;
  List.iter (rollback_staged_cell tx.core.id) (List.rev tx.core.staged_cells);
  tx.core.staged_cells <- [];
  tx.core.state <- Rolled_back;
  List.iter (fun hook -> hook ()) (List.rev tx.core.rollback_hooks);
  tx.core.rollback_hooks <- [];
  tx.core.commit_hooks <- [];
  tx.core.preflight_hooks <- []
