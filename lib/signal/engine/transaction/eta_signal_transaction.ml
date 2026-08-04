type id = unit ref

type planning
type sealed
type committed

type state =
  | Planning
  | Sealed
  | Committed
  | Rolled_back

type cell = {
  mutable current : Obj.t;
  mutable pending : Obj.t;
  mutable owner : id;
  mutable active : bool;
}

type 'a staged = cell

let no_owner = ref ()

let unused_cell =
  {
    current = Obj.repr ();
    pending = Obj.repr ();
    owner = no_owner;
    active = false;
  }

type 'error core = {
  id : id;
  mutable state : state;
  mutable cells : cell array;
  mutable cell_count : int;
}

type (+'phase, 'error) t = { core : 'error core }

type current_writer = Current_writer of string

let initialize_current = Current_writer "initialize_current"
let source_publication = Current_writer "source_publication"
let observer_publication = Current_writer "observer_publication"
let timer_lifecycle = Current_writer "timer_lifecycle"

let create_staged current =
  let value = Obj.repr current in
  { current = value; pending = value; owner = no_owner; active = false }

let current cell = Obj.obj cell.current

let publish_current (Current_writer writer) cell value =
  if cell.active then
    invalid_arg
      ("Eta_signal_transaction.publish_current(" ^ writer
     ^ "): staged value has pending transaction state");
  cell.current <- Obj.repr value

let id tx = tx.core.id
let equal_id left right = left == right

let begin_planning () =
  {
    core =
      {
        id = ref ();
        state = Planning;
        cells = Array.make 8 unused_cell;
        cell_count = 0;
      };
  }

let state_label = function
  | Planning -> "planning"
  | Sealed -> "sealed"
  | Committed -> "committed"
  | Rolled_back -> "rolled back"

let require_planning name tx =
  match tx.core.state with
  | Planning -> ()
  | state ->
      invalid_arg
        ("Eta_signal_transaction." ^ name ^ ": transaction is "
       ^ state_label state)

let read tx cell =
  if cell.active && equal_id cell.owner tx.core.id
  then Obj.obj cell.pending
  else Obj.obj cell.current

let staged tx cell =
  cell.active && equal_id cell.owner tx.core.id

let grow tx =
  let previous = tx.core.cells in
  let next = Array.make (Array.length previous * 2) unused_cell in
  Array.blit previous 0 next 0 tx.core.cell_count;
  tx.core.cells <- next

let remember_cell tx cell =
  if tx.core.cell_count = Array.length tx.core.cells then grow tx;
  tx.core.cells.(tx.core.cell_count) <- cell;
  tx.core.cell_count <- tx.core.cell_count + 1

let stage tx cell value =
  require_planning "stage" tx;
  if cell.active then (
    if not (equal_id cell.owner tx.core.id) then
      invalid_arg
        "Eta_signal_transaction.stage: staged value belongs to another \
         transaction")
  else (
    cell.active <- true;
    cell.owner <- tx.core.id;
    remember_cell tx cell);
  cell.pending <- Obj.repr value

let discard tx cell =
  require_planning "discard" tx;
  if cell.active then
    if equal_id cell.owner tx.core.id then (
      cell.active <- false;
      cell.owner <- no_owner)
    else
      invalid_arg
        "Eta_signal_transaction.discard: staged value belongs to another \
         transaction"

let change_phase tx = { core = tx.core }

let seal tx run =
  require_planning "seal" tx;
  match run () with
  | Error _ as error -> error
  | Ok () ->
      tx.core.state <- Sealed;
      Ok (change_phase tx)

let clear_cell id ~commit cell =
  if cell.active && equal_id cell.owner id then (
    if commit then cell.current <- cell.pending;
    cell.active <- false;
    cell.owner <- no_owner)

let clear_cells tx ~commit =
  for index = 0 to tx.core.cell_count - 1 do
    clear_cell tx.core.id ~commit tx.core.cells.(index);
    tx.core.cells.(index) <- unused_cell
  done;
  tx.core.cell_count <- 0

let commit tx =
  (match tx.core.state with
  | Sealed -> ()
  | state ->
      invalid_arg
        ("Eta_signal_transaction.commit: transaction is " ^ state_label state));
  clear_cells tx ~commit:true;
  tx.core.state <- Committed;
  change_phase tx

let rollback tx =
  (match tx.core.state with
  | Planning | Sealed -> ()
  | state ->
      invalid_arg
        ("Eta_signal_transaction.rollback: transaction is "
       ^ state_label state));
  clear_cells tx ~commit:false;
  tx.core.state <- Rolled_back
