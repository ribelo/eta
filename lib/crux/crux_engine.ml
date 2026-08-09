type never = |

module Cutoff = struct
  type 'a t = 'a -> 'a -> bool

  let always _published _candidate = true
  let never _published _candidate = false
  let phys_equal published candidate = published == candidate
  let of_equal equal = equal
  let of_compare compare published candidate = compare published candidate = 0
  let to_signal cutoff = Eta_signal.Cutoff.of_equal cutoff
end

module Diagnostic = Crux_failure.Diagnostic
module Failure = Crux_failure.Failure

module Int = struct
  type t = int

  let compare = Int.compare
end

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
  mutable scopes : scope_state Int_map.t;
  mutable endpoints : endpoint_core Int_map.t;
  mutable boundary_exports : boundary_export Int_map.t;
  mutable failure : Failure.t option;
  mutable failure_reported : bool;
  mutable next_scope : int;
  mutable next_endpoint : int;
  mutable next_position : int64;
  mutable dispose_signal : (unit -> (unit, staging_error) Eta.Effect.t) option;
  memo : (int * int, Obj.t) Hashtbl.t;
}

and endpoint_core = {
  id : int;
  root : root_core;
  scope : int;
  generation : int;
  mutable active : bool;
  dispatch : staging -> Obj.t -> unit;
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

(* Staging for one advancement. Model updates become Signal variable sets
   that run before the single stabilization; dormant works join the frame
   works in the post-commit batch; [undos] restore machine cells on
   rollback. *)
and staging = {
  mutable model_sets : (unit -> (unit, Eta_signal.graph_error) result) list;
  mutable undos : (unit -> unit) list;
  mutable works : work list;
  mutable message_owner : int option;
}

(* The published manifest of one description tree. Frames carry
   contributions; the root diffs consecutive frames: fresh records (works,
   endpoints, hooks, revokers) are detected by physical identity, scopes by
   scope id. *)
and contribution = {
  endpoints : endpoint_core list;
  works : work list;
  added_scopes : scope_state list;
  commit_hooks : (unit -> unit) list;
  added_revokers : (int * (unit -> unit)) list;
}

and 'output frame = {
  output : 'output;
  contribution : contribution;
}

and staging_error =
  [ Eta_signal.graph_error
  | `Observer_error of Eta_signal.No_observer_error.t
  | `Disposed_observer
  | `No_current_value
  | `Uninitialized_observer ]

and machine_cell = {
  mutable current_model : Obj.t;
  mutable current_input : Obj.t;
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

type owned_context = {
  root : root_core;
  scope : int;
}

let owned_context_local =
  Eta.Runtime_contract.create_local
    ~inheritance:Eta.Runtime_contract.Inherit ()

let with_owned_context root scope eff =
  Eta.Spi.Expert.with_local owned_context_local
    ({ root; scope } : owned_context) eff

let current_owned_context () =
  Eta.Spi.Expert.current_local owned_context_local

let absurd (value : never) = match value with _ -> .

let next_global =
  let counter = Atomic.make 0 in
  fun name ->
    let value = Atomic.fetch_and_add counter 1 in
    if value = max_int then invalid_arg ("Eta_crux: " ^ name ^ " overflow");
    value

let create_staging () =
  { model_sets = []; undos = []; works = []; message_owner = None }

let contribution_empty =
  {
    endpoints = [];
    works = [];
    added_scopes = [];
    commit_hooks = [];
    added_revokers = [];
  }

let contribution_append (left : contribution) (right : contribution) :
    contribution =
  {
    endpoints = left.endpoints @ right.endpoints;
    works = left.works @ right.works;
    added_scopes = left.added_scopes @ right.added_scopes;
    commit_hooks = left.commit_hooks @ right.commit_hooks;
    added_revokers = left.added_revokers @ right.added_revokers;
  }

(* Semantic manifest equality: two contributions publish the same lifecycle
   state when their scopes, endpoints, works, hooks, and revokers match by
   identity (ids for registered records, physical for staged ones). Gated
   nodes use it to suppress value-stable frames without freezing the
   manifest channel. *)
let contribution_equal (left : contribution) (right : contribution) =
  let same_by same xs ys =
    List.length xs = List.length ys && List.for_all2 same xs ys
  in
  same_by (fun (left : scope_state) (right : scope_state) -> left.id = right.id)
    (left : contribution).added_scopes right.added_scopes
  && same_by (fun (left : endpoint_core) (right : endpoint_core) -> left.id = right.id)
       (left : contribution).endpoints right.endpoints
  && same_by ( == ) (left : contribution).works right.works
  && same_by ( == )
       (left : contribution).commit_hooks right.commit_hooks
  && same_by ( == )
       (left : contribution).added_revokers right.added_revokers

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

(* Allocate a scope without registering it; the scope becomes visible when
   the frame that carries it is installed. *)
let fresh_scope (root : root_core) ~parent =
  if root.next_scope = max_int then
    invalid_arg "Eta_crux: scope identity overflow";
  let id = root.next_scope in
  root.next_scope <- id + 1;
  { id; parent = Some parent; active = false; jobs = []; revokers = [] }

let scope_is_descendant scopes ~ancestor scope =
  let rec loop current =
    if current = ancestor then true
    else
      match Int_map.find_opt current scopes with
      | Some { parent = Some parent; _ } -> loop parent
      | Some { parent = None; _ } | None -> false
  in
  loop scope

let scope_live root scope =
  match Int_map.find_opt scope root.scopes with
  | Some state -> state.active
  | None -> false

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

module type SIGNAL =
  module type of Eta_signal.Make (Eta_signal.No_observer_error) ()

(* Descriptions stay graph-neutral. A compile context carries the root's
   private Signal instance packed behind a first-class module; every
   combinator unpacks it locally and crosses child signals over an Obj
   boundary, the same discipline the old engine used for memo cells. One
   compile tree always shares one instance, so the casts are sound. *)
type packed_package = Pkg : (module SIGNAL) -> packed_package

type 'a packed = Packed : Obj.t -> 'a packed

type compile_ctx = {
  ctx_root : root_core;
  ctx_scope : int;
  ctx_package : packed_package;
}

(* Compile results memoize by (scope, description identity), the old cell
   key: a description value used twice in one scope compiles once, and
   branch reincarnations recompile because each branch owns a fresh scope. *)

type 'a t = {
  id : int;
  compile : compile_ctx -> ('a * contribution) packed;
}

let make compile =
  let id = next_global "description identity" in
  {
    id;
    compile =
      (fun ctx ->
        let key = (ctx.ctx_scope, id) in
        match Hashtbl.find_opt ctx.ctx_root.memo key with
        | Some packed -> Packed packed
        | None ->
            let (Packed packed) = compile ctx in
            Hashtbl.add ctx.ctx_root.memo key packed;
            Packed packed);
  }

let unpack_package ctx =
  let (Pkg pkg) = ctx.ctx_package in
  (module (val pkg : SIGNAL) : SIGNAL)

let pack_signal signal = Packed (Obj.repr signal)
let unpack_signal (Packed packed) = Obj.obj packed

let const_contribution value = (value, contribution_empty)

let return value =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  pack_signal (S.const (const_contribution value))

let map input ~f =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  let signal : ('a * contribution) S.signal =
    unpack_signal (input.compile ctx)
  in
  pack_signal
    (S.map
       (fun (value, (contribution : contribution)) -> (f value, contribution))
       signal)

let both left right =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  let left_signal : ('a * contribution) S.signal =
    unpack_signal (left.compile ctx)
  in
  let right_signal : ('b * contribution) S.signal =
    unpack_signal (right.compile ctx)
  in
  pack_signal
    (S.map2
       (fun (left_value, left_contribution) (right_value, (right_contribution : contribution)) ->
         ( (left_value, right_value),
           contribution_append left_contribution right_contribution ))
       left_signal right_signal)

let cutoff input ~cutoff =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  let signal : ('a * contribution) S.signal =
    unpack_signal (input.compile ctx)
  in
  let value =
    S.map ~cutoff:(Cutoff.to_signal cutoff) fst signal
  in
  let contribution =
    S.map
      ~cutoff:(Eta_signal.Cutoff.of_equal contribution_equal)
      snd signal
  in
  (* Value suppression and structural manifests are independent channels.
     Manifest churn republishes the last accepted value. *)
  pack_signal
    (S.map2
       (fun value contribution -> (value, contribution))
       value contribution)

(* A bind branch allocates one fresh Crux scope per incarnation. Signal
   rebuilds the branch when the selector publishes, which closes the previous
   branch's scope through the frame diff. *)
let bind selector ~f =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  let selector_signal : ('a * contribution) S.signal =
    unpack_signal (selector.compile ctx)
  in
  pack_signal
    (S.bind
       (S.map fst selector_signal)
       ~f:(fun selected ->
         let scope = fresh_scope ctx.ctx_root ~parent:ctx.ctx_scope in
         let child_ctx = { ctx with ctx_scope = scope.id } in
         let child : ('b * contribution) S.signal =
           unpack_signal ((f selected).compile child_ctx)
         in
         S.map2
           (fun (_, selector_contribution)
                (value, (child_contribution : contribution)) ->
             let contribution =
               contribution_append selector_contribution child_contribution
             in
             ( value,
               {
                 contribution with
                 added_scopes = scope :: contribution.added_scopes;
               } ))
           selector_signal child))

module Syntax = struct
  let ( let+ ) value f = map value ~f
  let ( and+ ) = both
  let ( let* ) value f = bind value ~f
end

module State_machine = struct
  let create (type model input action)
      ?(model_cutoff = Cutoff.phys_equal) ?diagnostics
      (input_description : input t) ~(default_model : model) ~apply_action =
    let node = next_global "state-machine node" in
    make @@ fun ctx ->
    let (module S) = unpack_package ctx in
    let root = ctx.ctx_root in
    let input_signal : (input * contribution) S.signal =
      unpack_signal (input_description.compile ctx)
    in
    if root.next_endpoint = max_int then
      invalid_arg "Eta_crux: endpoint identity overflow";
    let endpoint_id = root.next_endpoint in
    root.next_endpoint <- endpoint_id + 1;
    let equal_model left right =
      model_cutoff (Obj.obj left) (Obj.obj right)
    in
    let apply endpoint ~input ~model ~action =
      let self =
        ({ Endpoint.core = endpoint; encode = Obj.repr } : action Endpoint.t)
      in
      let model, eff =
        apply_action ~self ~input:(Obj.obj input) ~model:(Obj.obj model)
          ~action:(Obj.obj action)
      in
      (Obj.repr model, eff)
    in
    let diagnostics =
      Option.map
        (fun (diagnostics : (model, action) Diagnostic.state_machine) ->
          ( (fun model -> diagnostics.model (Obj.obj model)),
            (fun action -> diagnostics.action (Obj.obj action)) ))
        diagnostics
    in
    let model_var =
      S.Var.create ~cutoff:Eta_signal.Cutoff.never default_model
    in
    let cell =
      {
        current_model = Obj.repr default_model;
        current_input = Obj.repr None;
        equal_model;
        diagnostics;
        apply;
      }
    in
    let rec endpoint =
      {
        id = endpoint_id;
        root;
        scope = ctx.ctx_scope;
        generation = endpoint_id;
        active = false;
        dispatch =
          (fun staging action ->
            let model, eff =
              try
                cell.apply endpoint ~input:cell.current_input
                  ~model:cell.current_model ~action
              with exn ->
                let action_snapshot, model_snapshot, hook_failures =
                  match cell.diagnostics with
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
                        capture model_diagnostic cell.current_model
                      in
                      ( action_snapshot,
                        model_snapshot,
                        action_failures @ model_failures )
                in
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
                    endpoint = Some endpoint.id;
                    trigger = Failure.Endpoint_message;
                    position = 0L;
                    action_snapshot;
                    model_snapshot;
                  };
                List.iter
                  (fun hook_exn ->
                    latch_exception root ~cell:node ~endpoint:endpoint.id
                      ~origin:Failure.Crash_handler
                      ~trigger:Failure.Application_crash_handler hook_exn)
                  hook_failures;
                raise Failure_already_latched
            in
            let previous = cell.current_model in
            cell.current_model <- model;
            staging.model_sets <-
              (fun () -> S.Var.set model_var (Obj.obj model))
              :: staging.model_sets;
            staging.undos <- (fun () -> cell.current_model <- previous)
              :: staging.undos;
            staging.works <-
              {
                scope =
                  (match staging.message_owner with
                  | Some owner -> owner
                  | None -> endpoint.scope);
                origin = Failure.Owned_work;
                trigger = Failure.Transition_effect;
                payload = Program eff;
              }
              :: staging.works);
      }
    in
    let public_endpoint =
      ({ Endpoint.core = endpoint; encode = Obj.repr } : action Endpoint.t)
    in
    (* The watcher refreshes the cell's input on every input publication;
       the gated model republishes only when the model changes. The output
       republishes when the gated model moves or when the input subtree's
       contribution churns, which mirrors the old model_version gate while
       keeping scope and endpoint manifests current. *)
    let watcher =
      S.map
        (fun (input, (contribution : contribution)) ->
          cell.current_input <- Obj.repr input;
          ((), contribution))
        input_signal
    in
    let gated_model =
      S.map
        ~cutoff:
          (Eta_signal.Cutoff.of_equal (fun left right ->
               equal_model (Obj.repr left) (Obj.repr right)))
        Fun.id (S.Var.watch model_var)
    in
    pack_signal
      (S.map2
         ~cutoff:
           (Eta_signal.Cutoff.of_equal (fun left right ->
                equal_model
                  (Obj.repr (fst (fst left)))
                  (Obj.repr (fst (fst right)))
                && contribution_equal (snd left) (snd right)))
         (fun gated ((), (contribution : contribution)) ->
           ( (gated, public_endpoint),
             { contribution with endpoints = endpoint :: contribution.endpoints }
           ))
         gated_model watcher)
end

let lifecycle effect_description =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  let signal : ((unit, never) Eta.Effect.t * contribution) S.signal =
    unpack_signal (effect_description.compile ctx)
  in
  (* The work record is allocated once per branch incarnation, so the root
     stages it exactly once, when the first frame carrying it is installed. *)
  let staged = ref None in
  pack_signal
    (S.map
       (fun (eff, (contribution : contribution)) ->
         let work =
           match !staged with
           | Some work -> work
           | None ->
               let work =
                 {
                   scope = ctx.ctx_scope;
                   origin = Failure.Owned_work;
                   trigger = Failure.Lifecycle_program;
                   payload = Program eff;
                 }
               in
               staged := Some work;
               work
         in
         ( (), { contribution with works = work :: contribution.works } ))
       signal)

module Assoc = struct
  module Make (Order : Eta_signal_map.Map.Ordered_type) = struct
    module M = Eta_signal_map.Map.Make (Order)

    let assoc ?(data_cutoff = Cutoff.phys_equal) input_description ~f =
      make @@ fun ctx ->
      let (module S) = unpack_package ctx in
      let module Signal_map = Eta_signal_map.Make (S.Package) in
      let module Keyed = Signal_map.Keyed (Order) in
      let input_signal : ('data M.t * contribution) S.signal =
        unpack_signal (input_description.compile ctx)
      in
      let data_description (data : 'data S.signal) : 'data t =
        {
          id = next_global "assoc data description";
          compile =
            (fun _ctx ->
              pack_signal
                (S.map (fun value -> (value, contribution_empty)) data));
        }
      in
      let children =
        Keyed.mapi
          ~data_cutoff:(Cutoff.to_signal data_cutoff)
          (S.map fst input_signal)
          ~f:(fun ~key ~data ->
            let scope = fresh_scope ctx.ctx_root ~parent:ctx.ctx_scope in
            let child_ctx = { ctx with ctx_scope = scope.id } in
            let child : ('result * contribution) S.signal =
              unpack_signal
                ((f ~key ~data:(data_description data)).compile child_ctx)
            in
            S.map
              (fun (value, (contribution : contribution)) ->
                ( value,
                  {
                    contribution with
                    added_scopes = scope :: contribution.added_scopes;
                  } ))
              child)
      in
      pack_signal
        (S.map2
           (fun (_, (input_contribution : contribution)) children_map ->
             let output =
               M.map (fun (value, _) -> value) children_map
             in
             let contribution =
               M.fold
                 (fun _key (_, child) acc ->
                   contribution_append acc child)
                 children_map
                 contribution_empty
             in
             (output, contribution_append input_contribution contribution))
           input_signal children)
  end
end

let pp_staging_error fmt (error : staging_error) =
  match error with
  | `Ambiguous_scope -> Format.pp_print_string fmt "ambiguous scope"
  | `Counter_overflow label ->
      Format.fprintf fmt "counter overflow: %s" label
  | `Cycle -> Format.pp_print_string fmt "cycle"
  | `Invalid_scope -> Format.pp_print_string fmt "invalid scope"
  | `Reentrant_stabilization ->
      Format.pp_print_string fmt "reentrant stabilization"
  | `Runtime_mismatch -> Format.pp_print_string fmt "runtime mismatch"
  | `Reentrant_update -> Format.pp_print_string fmt "reentrant update"
  | `Observer_error _ -> .
  | `Disposed_observer -> Format.pp_print_string fmt "disposed observer"
  | `No_current_value -> Format.pp_print_string fmt "no current value"
  | `Uninitialized_observer ->
      Format.pp_print_string fmt "uninitialized observer"

(* Root integration. Construction is synchronous (graph construction); the
   private output observer is created lazily inside the first effectful
   advancement because observer registration is an Eta effect. *)
type 'output signal_root = {
  sig_ensure_observer : (unit, staging_error) Eta.Effect.t;
  sig_stabilize : (unit, staging_error) Eta.Effect.t;
  sig_read_frame : unit -> ('output frame, staging_error) Eta.Effect.t;
  sig_dispose_observer : unit -> (unit, staging_error) Eta.Effect.t;
}

let create_signal_root (root : root_core) (description : 'output t) :
    'output signal_root =
  let module S = Eta_signal.Make (Eta_signal.No_observer_error) () in
  let ctx =
    { ctx_root = root; ctx_scope = 0; ctx_package = Pkg (module S) }
  in
  let compiled : ('output * contribution) S.signal =
    unpack_signal (description.compile ctx)
  in
  let frame_signal =
    S.map ~cutoff:Eta_signal.Cutoff.never
      (fun (output, (contribution : contribution)) -> { output; contribution })
      compiled
  in
  (* Signal operations are synchronous results; defer them behind [E.sync]
     so they execute when the effect is interpreted, not when this record is
     constructed. *)
  let sync_result f =
    Eta.Effect.bind Eta.Effect.from_result (Eta.Effect.sync f)
  in
  let observer_ref = ref None in
  let ensure_observer =
    Eta.Effect.bind
      (fun observed ->
        if observed then Eta.Effect.unit
        else
          sync_result (fun () -> S.Observer.observe frame_signal)
          |> Eta.Effect.map_error (fun err -> (err :> staging_error))
          |> Eta.Effect.map (fun observer -> observer_ref := Some observer))
      (Eta.Effect.sync (fun () -> Option.is_some !observer_ref))
  in
  let sig_read_frame () =
    match !observer_ref with
    | None -> Eta.Effect.fail `Invalid_scope
    | Some observer ->
        sync_result (fun () -> S.Observer.read observer)
        |> Eta.Effect.map_error (fun err -> (err :> staging_error))
  in
  {
    sig_ensure_observer = ensure_observer;
    sig_stabilize =
      sync_result (fun () -> S.stabilize ())
      |> Eta.Effect.map_error (fun err -> (err :> staging_error));
    sig_read_frame;
    sig_dispose_observer =
      (fun () ->
        match !observer_ref with
        | None -> Eta.Effect.unit
        | Some observer ->
            sync_result (fun () -> S.Observer.dispose observer)
            |> Eta.Effect.map_error (fun err -> (err :> staging_error)));
  }
