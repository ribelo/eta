type never = |

module Diagnostic = Crux_failure.Diagnostic
module Failure = Crux_failure.Failure

module Cell_key = struct
  type t = int * int
  let compare = Stdlib.compare
end

module Cell_map = Map.Make (Cell_key)
module Int_map = Map.Make (Int)
module Int_set = Set.Make (Int)

type root_phase =
  | Ready
  | Advancing
  | Awaiting_post_commit
  | Closed

type boundary_endpoint_result =
  | Boundary_endpoint_accepted
  | Boundary_endpoint_full
  | Boundary_endpoint_ingress_closed
  | Boundary_endpoint_revoked
  | Boundary_endpoint_malformed_payload

type boundary_request_closure =
  | Boundary_initiator_cancelled
  | Boundary_owner_disposed
  | Boundary_root_stopped
  | Boundary_root_crashed
  | Boundary_session_closed

type boundary_request_identity_result =
  | Boundary_request_accepted
  | Boundary_request_not_pending

type boundary_request_completion =
  | Boundary_request_resolved of bytes
  | Boundary_request_closed of boundary_request_closure
  | Boundary_request_cancelled_by_peer

type boundary_remote_request = {
  completion :
    (boundary_request_completion, never) Eta.Effect.t;
  cancel_by_peer :
    unit ->
    (boundary_request_identity_result, never) Eta.Effect.t;
  close :
    boundary_request_closure ->
    (boundary_request_identity_result, never) Eta.Effect.t;
}

type boundary_request_start_result =
  | Boundary_request_started of boundary_remote_request
  | Boundary_request_capacity_full
  | Boundary_ingress_capacity_full
  | Boundary_request_ingress_closed
  | Boundary_request_malformed_handle
  | Boundary_request_unknown_handle
  | Boundary_request_stale_handle
  | Boundary_request_revoked
  | Boundary_request_malformed_payload

type boundary_export_kind =
  | Boundary_endpoint of {
      invoke : bytes -> boundary_endpoint_result;
    }
  | Boundary_request of {
      start :
        bytes ->
        (boundary_request_start_result, never) Eta.Effect.t;
      close_all : boundary_request_closure -> unit;
    }

type boundary_export = {
  identity : int;
  kind : boundary_export_kind;
}

type scope_state = {
  id : int;
  parent : int option;
  mutable active : bool;
  mutable jobs : owned_job list;
  mutable revokers : (unit -> unit) list;
}

and owned_job = {
  scope : int;
  ancestors : int list;
  cancel : (owned_job list, never) Eta.Promise.t;
  settled : (unit, never) Eta.Promise.t;
}

type root_core = {
  id : int;
  lock : Eta.Sync_lock.t;
  ingress : (message, never) Eta.Queue.t;
  wake : (unit, never) Eta.Queue.t;
  terminal_wake : (unit, never) Eta.Queue.t;
  request_slots : Eta.Semaphore.t;
  ingress_capacity : int;
  request_capacity : int;
  mutable phase : root_phase;
  mutable start_pending : bool;
  mutable stop_requested : bool;
  store :
    Obj.t Eta_signal.Owner_transaction.cell Cell_map.t
    Eta_signal.Owner_transaction.cell;
  mutable scopes : scope_state Int_map.t;
  mutable endpoints : endpoint_core Int_map.t;
  mutable boundary_exports : boundary_export Int_map.t;
  mutable failure : Failure.t option;
  mutable failure_reported : bool;
  mutable next_scope : int;
  mutable next_endpoint : int;
  mutable next_version : int;
  mutable next_position : int64;
}

and endpoint_core = {
  id : int;
  root : root_core;
  scope : int;
  generation : int;
  mutable active : bool;
  dispatch : transaction -> Obj.t -> unit;
}

and message =
  | Message of {
      endpoint : endpoint_core;
      action : Obj.t;
      owner_scope : int option;
    }

and work = {
  scope : int;
  origin : Failure.origin;
  trigger : Failure.trigger_kind;
  payload : work_payload;
}

and work_payload =
  | Program of (unit, never) Eta.Effect.t
  | Source_open of
      ((unit, never) Eta.Effect.t option, never) Eta.Effect.t

and data_update =
  | Data_update : {
      source : data_source;
      value : Obj.t;
      version : int;
    } -> data_update

and data_source = {
  id : int;
  mutable value : Obj.t;
  mutable version : int;
}

and transaction = {
  root : root_core;
  owner_transaction : Eta_signal.Owner_transaction.t;
  mutable owner_committed : bool;
  mutable overlay :
    Obj.t Eta_signal.Owner_transaction.cell Cell_map.t;
  mutable added_scopes : scope_state list;
  mutable removed_scopes : int list;
  mutable added_endpoints : endpoint_core list;
  mutable works : work list;
  mutable data_updates : data_update list;
  mutable commit_hooks : (unit -> unit) list;
  mutable removed_jobs : owned_job list;
  mutable message_owner : int option;
  mutable added_revokers : (int * (unit -> unit)) list;
}

type owned_context = {
  root : root_core;
  scope : int;
}

let owned_context_local =
  Eta.Runtime_contract.create_local
    ~inheritance:Eta.Runtime_contract.Inherit ()

let with_owned_context root scope effect =
  Eta.Spi.Expert.with_local owned_context_local { root; scope } effect

let current_owned_context () =
  Eta.Spi.Expert.current_local owned_context_local

type 'a computed = {
  value : 'a;
  version : int;
}

type 'a t = {
  id : int;
  eval : transaction -> int -> 'a computed;
}

let absurd (value : never) = match value with _ -> .

let next_global =
  let counter = Atomic.make 0 in
  fun name ->
    let value = Atomic.fetch_and_add counter 1 in
    if value = max_int then invalid_arg ("Eta_crux: " ^ name ^ " overflow");
    value

let make_description eval = { id = next_global "description identity"; eval }

let fresh_version root =
  if root.next_version = max_int then invalid_arg "Eta_crux: version overflow";
  let version = root.next_version in
  root.next_version <- version + 1;
  version

let fresh_scope (transaction : transaction) ~parent =
  let root = transaction.root in
  if root.next_scope = max_int then invalid_arg "Eta_crux: scope identity overflow";
  let id = root.next_scope in
  root.next_scope <- id + 1;
  let scope =
    { id; parent = Some parent; active = false; jobs = []; revokers = [] }
  in
  transaction.added_scopes <- scope :: transaction.added_scopes;
  id

let transaction_get (transaction : transaction) key =
  let cell =
    match Cell_map.find_opt key transaction.overlay with
    | Some cell -> Some cell
    | None ->
        Cell_map.find_opt key
          (Eta_signal.Owner_transaction.read
             transaction.owner_transaction transaction.root.store)
  in
  Option.map
    (Eta_signal.Owner_transaction.read
       transaction.owner_transaction)
    cell

let transaction_set (transaction : transaction) key value =
  let cell =
    match Cell_map.find_opt key transaction.overlay with
    | Some cell -> cell
    | None -> (
        let store =
          Eta_signal.Owner_transaction.read
            transaction.owner_transaction transaction.root.store
        in
        match Cell_map.find_opt key store with
        | Some cell -> cell
        | None ->
            let cell =
              Eta_signal.Owner_transaction.create_cell
                (Obj.repr value)
            in
            transaction.overlay <-
              Cell_map.add key cell transaction.overlay;
            cell)
  in
  Eta_signal.Owner_transaction.stage
    transaction.owner_transaction cell (Obj.repr value)

let data_value (transaction : transaction) (source : data_source) =
  let rec find = function
    | [] -> (Obj.obj source.value, source.version)
    | Data_update update :: rest ->
        if update.source == source then
          (Obj.obj update.value, update.version)
        else find rest
  in
  find transaction.data_updates

let stage_data (transaction : transaction) (source : data_source) value =
  let version = fresh_version transaction.root in
  transaction.data_updates <-
    Data_update { source; value = Obj.repr value; version }
    :: transaction.data_updates;
  version

let scope_is_descendant scopes ~ancestor scope =
  let rec loop current =
    if current = ancestor then true
    else
      match Int_map.find_opt current scopes with
      | Some { parent = Some parent; _ } -> loop parent
      | Some { parent = None; _ } | None -> false
  in
  loop scope

let failure_record root ?cell ?endpoint ~origin ~trigger cause =
  ignore root;
  {
    Failure.cause;
    origin;
    cell;
    endpoint;
    trigger;
    position = 0L;
    action_snapshot = None;
    model_snapshot = None;
  }

let shutdown_ingress root = Eta.Queue.shutdown root.ingress

let latch_failure_record (root : root_core) (record : Failure.record) =
  let first =
    Eta.Sync_lock.use root.lock @@ fun () ->
    if root.next_position = Int64.max_int then
      invalid_arg "Eta_crux: observation position overflow";
    let record =
      { record with Failure.position = root.next_position }
    in
    root.next_position <- Int64.succ root.next_position;
    match root.failure with
    | None ->
        root.failure <- Some { Failure.primary = record; secondary = [] };
        root.stop_requested <- false;
        true
    | Some failure ->
        root.failure <-
          Some
            {
              failure with
              secondary = failure.secondary @ [ record ];
            };
        false
  in
  if first then (
    shutdown_ingress root;
    ignore (Eta.Queue.try_offer_now root.wake () : _);
    ignore (Eta.Queue.try_offer_now root.terminal_wake () : _))

let latch_exception root ?cell ?endpoint ~origin ~trigger exn =
  let cause =
    Failure.Packed_cause.make
      ~pp_error:(fun _ (value : never) -> absurd value)
      (Eta.Cause.die exn)
  in
  latch_failure_record root
    (failure_record root ?cell ?endpoint ~origin ~trigger cause)

exception Failure_already_latched

module Endpoint = struct
  type 'message t = {
    core : endpoint_core;
    encode : 'message -> Obj.t;
  }

  type admission_error = Ingress_closed

  let send_with_owner endpoint ~owner_scope message =
    let root = endpoint.core.root in
    Eta.Queue.send root.ingress
      (Message
         {
           endpoint = endpoint.core;
           action = endpoint.encode message;
           owner_scope;
         })
    |> Eta.Effect.map_error (function
         | `Closed -> Ingress_closed
         | `Dropped ->
             invalid_arg "Eta_crux.Endpoint.send: bounded ingress dropped a value"
         | `Closed_with_error (_ : never) -> .)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.sync (fun () ->
               ignore (Eta.Queue.try_offer_now root.wake () : _)))

  let send endpoint message =
    send_with_owner endpoint ~owner_scope:None message

  let send_owned endpoint ~scope message =
    send_with_owner endpoint ~owner_scope:(Some scope) message

  let contramap target ~f =
    {
      core = target.core;
      encode = (fun source -> target.encode (f source));
    }
end

let return value =
  let node = next_global "constant node" in
  make_description @@ fun transaction scope ->
  let key = (scope, node) in
  match transaction_get transaction key with
  | Some packed -> Obj.obj packed
  | None ->
      let result = { value; version = fresh_version transaction.root } in
      transaction_set transaction key result;
      result

let map input ~f =
  let node = next_global "map node" in
  make_description @@ fun transaction scope ->
  let dependency = input.eval transaction scope in
  let key = (scope, node) in
  match transaction_get transaction key with
  | Some packed ->
      let dependency_version, result = Obj.obj packed in
      if dependency_version = dependency.version then result
      else
        let result =
          {
            value = f dependency.value;
            version = fresh_version transaction.root;
          }
        in
        transaction_set transaction key (dependency.version, result);
        result
  | None ->
      let result =
        {
          value = f dependency.value;
          version = fresh_version transaction.root;
        }
      in
      transaction_set transaction key (dependency.version, result);
      result

let both left right =
  let node = next_global "both node" in
  make_description @@ fun transaction scope ->
  let left_value = left.eval transaction scope in
  let right_value = right.eval transaction scope in
  let key = (scope, node) in
  match transaction_get transaction key with
  | Some packed ->
      let left_version, right_version, result = Obj.obj packed in
      if
        left_version = left_value.version
        && right_version = right_value.version
      then result
      else
        let result =
          {
            value = (left_value.value, right_value.value);
            version = fresh_version transaction.root;
          }
        in
        transaction_set transaction key
          (left_value.version, right_value.version, result);
        result
  | None ->
      let result =
        {
          value = (left_value.value, right_value.value);
          version = fresh_version transaction.root;
        }
      in
      transaction_set transaction key
        (left_value.version, right_value.version, result);
      result

let cutoff input ~equal =
  let node = next_global "cutoff node" in
  make_description @@ fun transaction scope ->
  let candidate = input.eval transaction scope in
  let key = (scope, node) in
  match transaction_get transaction key with
  | None ->
      transaction_set transaction key candidate;
      candidate
  | Some packed ->
      let published = (Obj.obj packed : _ computed) in
      if published.version = candidate.version then published
      else if equal published.value candidate.value then published
      else
        let result =
          {
            value = candidate.value;
            version = fresh_version transaction.root;
          }
        in
        transaction_set transaction key result;
        result

let bind selector ~f =
  let node = next_global "bind node" in
  make_description @@ fun transaction scope ->
  let selected = selector.eval transaction scope in
  let key = (scope, node) in
  let child, child_scope =
    match transaction_get transaction key with
    | None -> (f selected.value, fresh_scope transaction ~parent:scope)
    | Some packed ->
        let selector_version, child, child_scope = Obj.obj packed in
        if selector_version = selected.version then (child, child_scope)
        else
          let candidate = f selected.value in
          if candidate.id = child.id then (child, child_scope)
          else (
            transaction.removed_scopes <-
              child_scope :: transaction.removed_scopes;
            (candidate, fresh_scope transaction ~parent:scope))
  in
  transaction_set transaction key (selected.version, child, child_scope);
  child.eval transaction child_scope

module Syntax = struct
  let ( let+ ) value f = map value ~f
  let ( and+ ) = both
  let ( let* ) value f = bind value ~f
end

type machine_cell = {
  model : Obj.t;
  input : Obj.t;
  input_version : int;
  endpoint : endpoint_core;
  public_endpoint : Obj.t;
  model_version : int;
  equal_model : Obj.t -> Obj.t -> bool;
  diagnostics :
    ((Obj.t -> Diagnostic.snapshot) * (Obj.t -> Diagnostic.snapshot)) option;
  apply :
    endpoint_core ->
    input:Obj.t ->
    model:Obj.t ->
    action:Obj.t ->
    Obj.t * (unit, never) Eta.Effect.t;
}

module State_machine = struct
  let create (type model input action) ?equal ?diagnostics
      (input_description : input t) ~(default_model : model) ~apply_action =
    let node = next_global "state-machine node" in
    make_description @@ fun transaction scope ->
    let input = input_description.eval transaction scope in
    let key = (scope, node) in
    let cell =
      match transaction_get transaction key with
      | Some packed ->
          let cell = (Obj.obj packed : machine_cell) in
          if cell.input_version = input.version then cell
          else
            {
              cell with
              input = Obj.repr input.value;
              input_version = input.version;
            }
      | None ->
          let root = transaction.root in
          if root.next_endpoint = max_int then
            invalid_arg "Eta_crux: endpoint identity overflow";
          let endpoint_id = root.next_endpoint in
          root.next_endpoint <- endpoint_id + 1;
          let generation = endpoint_id in
          let rec endpoint =
            {
              id = endpoint_id;
              root;
              scope;
              generation;
              active = false;
              dispatch =
                (fun transaction action ->
                  let current =
                    match transaction_get transaction key with
                    | Some packed -> (Obj.obj packed : machine_cell)
                    | None ->
                        invalid_arg
                          "Eta_crux: live endpoint has no state-machine cell"
                  in
                  let model, effect =
                    try
                      current.apply current.endpoint ~input:current.input
                        ~model:current.model ~action
                    with exn ->
                      let action_snapshot, model_snapshot, hook_failures =
                        match current.diagnostics with
                        | None -> (None, None, [])
                        | Some (model_diagnostic, action_diagnostic) ->
                            let capture diagnostic value =
                              try (Some (diagnostic value), [])
                              with hook_exn -> (None, [ hook_exn ])
                            in
                            let action_snapshot, action_failures =
                              capture action_diagnostic action
                            in
                            let model_snapshot, model_failures =
                              capture model_diagnostic current.model
                            in
                            ( action_snapshot,
                              model_snapshot,
                              action_failures @ model_failures )
                      in
                      let root = transaction.root in
                      let cause =
                        Failure.Packed_cause.make
                          ~pp_error:(fun _ (value : never) -> absurd value)
                          (Eta.Cause.die exn)
                      in
                      latch_failure_record root
                        {
                          Failure.cause;
                          origin = Failure.Transition;
                          cell = Some node;
                          endpoint = Some current.endpoint.id;
                          trigger = Failure.Endpoint_message;
                          position = 0L;
                          action_snapshot;
                          model_snapshot;
                        };
                      List.iter
                        (fun hook_exn ->
                          latch_exception root ~cell:node
                            ~endpoint:current.endpoint.id
                            ~origin:Failure.Crash_handler
                            ~trigger:Failure.Application_crash_handler
                            hook_exn)
                        hook_failures;
                      raise Failure_already_latched
                  in
                  let changed = not (current.equal_model current.model model) in
                  let next =
                    {
                      current with
                      model;
                      model_version =
                        (if changed then fresh_version transaction.root
                         else current.model_version);
                    }
                  in
                  transaction_set transaction key next;
                  transaction.works <-
                    {
                      scope =
                        (match transaction.message_owner with
                        | Some owner -> owner
                        | None -> scope);
                      origin = Failure.Owned_work;
                      trigger = Failure.Transition_effect;
                      payload = Program effect;
                    }
                    :: transaction.works)
            }
          in
          let public_endpoint =
            ({ Endpoint.core = endpoint; encode = Obj.repr } : action Endpoint.t)
          in
          let equal_model left right =
            match equal with
            | None -> left == right
            | Some equal -> equal (Obj.obj left) (Obj.obj right)
          in
          let apply endpoint ~input ~model ~action =
            let self =
              ({ Endpoint.core = endpoint; encode = Obj.repr } :
                action Endpoint.t)
            in
            let model, effect =
              apply_action ~self ~input:(Obj.obj input) ~model:(Obj.obj model)
                ~action:(Obj.obj action)
            in
            (Obj.repr model, effect)
          in
          let diagnostics =
            Option.map
              (fun (diagnostics :
                     (model, action) Diagnostic.state_machine) ->
                ( (fun model -> diagnostics.model (Obj.obj model)),
                  (fun action -> diagnostics.action (Obj.obj action)) ))
              diagnostics
          in
          let cell =
            {
              model = Obj.repr default_model;
              input = Obj.repr input.value;
              input_version = input.version;
              endpoint;
              public_endpoint = Obj.repr public_endpoint;
              model_version = fresh_version root;
              equal_model;
              diagnostics;
              apply;
            }
          in
          transaction.added_endpoints <-
            endpoint :: transaction.added_endpoints;
          cell
    in
    transaction_set transaction key cell;
    {
      value = (Obj.obj cell.model, Obj.obj cell.public_endpoint);
      version = cell.model_version;
    }
end

let lifecycle effect_description =
  let node = next_global "lifecycle node" in
  make_description @@ fun transaction scope ->
  let effect = effect_description.eval transaction scope in
  let key = (scope, node) in
  (match transaction_get transaction key with
  | Some _ -> ()
  | None ->
      transaction_set transaction key true;
      transaction.works <-
        {
          scope;
          origin = Failure.Owned_work;
          trigger = Failure.Lifecycle_program;
          payload = Program effect.value;
        }
        :: transaction.works);
  { value = (); version = effect.version }
