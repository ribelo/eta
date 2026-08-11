module Testing = struct
  module Effect_id = struct
    type t = int64
    let compare = Int64.compare
    let pp formatter value = Format.fprintf formatter "%Ld" value
  end

  module Commit_index = struct
    type t = int64
    let compare = Int64.compare
    let pp formatter value = Format.fprintf formatter "%Ld" value
    let to_int64 value = value
  end

  module Event_position = struct
    type t = int64
    let compare = Int64.compare
    let pp formatter value = Format.fprintf formatter "%Ld" value
    let to_int64 value = value
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

  type post_commit_effect_observer = observer

  and observer = {
    lock : Eta.Sync_lock.t;
    events : event Queue.t;
    mutable attached : bool;
    mutable next_commit : int64;
    mutable next_effect : int64;
    mutable next_position : int64;
  }
end

type observer = Testing.observer

type observed_state =
  | Staged_state
  | Started_state
  | Terminal_state

type observed_effect = {
  observer : observer;
  id : Testing.Effect_id.t;
  mutable state : observed_state;
}

let create () =
  {
    Testing.lock = Eta.Sync_lock.create ();
    events = Queue.create ();
    attached = false;
    next_commit = 0L;
    next_effect = 0L;
    next_position = 0L;
  }

let claim observer =
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  if observer.attached then
    invalid_arg
      "Eta_crux.Root.create: post-commit effect observer is already attached";
  observer.attached <- true

let next_position observer =
  if observer.Testing.next_position = Int64.max_int then
    invalid_arg "Eta_crux.Testing: event position exhausted";
  let position = observer.next_position in
  observer.next_position <- Int64.succ position;
  position

let enqueue observer make =
  let position = next_position observer in
  Queue.add (make position) observer.Testing.events

let stage observer count =
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  if observer.next_commit = Int64.max_int then
    invalid_arg "Eta_crux.Testing: commit index exhausted";
  let commit = observer.next_commit in
  observer.next_commit <- Int64.succ commit;
  let rec allocate remaining effects observed =
    if remaining = 0 then (List.rev effects, List.rev observed)
    else (
      if observer.next_effect = Int64.max_int then
        invalid_arg "Eta_crux.Testing: effect identity exhausted";
      let id = observer.next_effect in
      observer.next_effect <- Int64.succ id;
      allocate (remaining - 1) (id :: effects)
        ({ observer; id; state = Staged_state } :: observed))
  in
  let effects, observed = allocate count [] [] in
  enqueue observer (fun position ->
      Testing.Staged { position; commit; effects });
  observed

let started effect =
  let observer = effect.observer in
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  match effect.state with
  | Staged_state ->
      effect.state <- Started_state;
      enqueue observer (fun position ->
          Testing.Started { position; effect = effect.id })
  | Started_state | Terminal_state ->
      invalid_arg "Eta_crux.Testing: effect started twice"

let settled effect settlement =
  let observer = effect.observer in
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  match effect.state with
  | Started_state ->
      effect.state <- Terminal_state;
      enqueue observer (fun position ->
          Testing.Settled
            { position; effect = effect.id; settlement })
  | Staged_state | Terminal_state ->
      invalid_arg "Eta_crux.Testing: invalid effect settlement"

let discarded effect =
  let observer = effect.observer in
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  match effect.state with
  | Staged_state ->
      effect.state <- Terminal_state;
      enqueue observer (fun position ->
          Testing.Discarded_before_start
            { position; effect = effect.id })
  | Started_state | Terminal_state ->
      invalid_arg "Eta_crux.Testing: invalid effect discard"

let poll observer =
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  Queue.take_opt observer.events

let drain observer =
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  let rec loop events =
    match Queue.take_opt observer.events with
    | None -> List.rev events
    | Some event -> loop (event :: events)
  in
  loop []

let is_empty observer =
  Eta.Sync_lock.use observer.Testing.lock @@ fun () ->
  Queue.is_empty observer.events
