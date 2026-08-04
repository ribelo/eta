type counters = {
  mutable enabled : bool;
  mutable admissions : int;
  mutable claims : int;
  mutable dependency_edge_visits : int;
  mutable propagation_edge_visits : int;
  mutable node_evaluations : int;
  mutable cutoff_calls : int;
}

type counter_snapshot = {
  admissions : int;
  claims : int;
  dependency_edge_visits : int;
  propagation_edge_visits : int;
  node_evaluations : int;
  cutoff_calls : int;
}

let create_counters () =
  {
    enabled = false;
    admissions = 0;
    claims = 0;
    dependency_edge_visits = 0;
    propagation_edge_visits = 0;
    node_evaluations = 0;
    cutoff_calls = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.admissions <- 0;
  counters.claims <- 0;
  counters.dependency_edge_visits <- 0;
  counters.propagation_edge_visits <- 0;
  counters.node_evaluations <- 0;
  counters.cutoff_calls <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    admissions = counters.admissions;
    claims = counters.claims;
    dependency_edge_visits = counters.dependency_edge_visits;
    propagation_edge_visits = counters.propagation_edge_visits;
    node_evaluations = counters.node_evaluations;
    cutoff_calls = counters.cutoff_calls;
  }

let succ value = if value = max_int then max_int else value + 1

let note_admission counters =
  if counters.enabled then counters.admissions <- succ counters.admissions

let note_claim counters =
  if counters.enabled then counters.claims <- succ counters.claims

let note_dependency_edge_visit counters =
  if counters.enabled then
    counters.dependency_edge_visits <- succ counters.dependency_edge_visits

let note_propagation_edge_visit counters =
  if counters.enabled then
    counters.propagation_edge_visits <- succ counters.propagation_edge_visits

let note_node_evaluation counters =
  if counters.enabled then
    counters.node_evaluations <- succ counters.node_evaluations

let note_cutoff_call counters =
  if counters.enabled then counters.cutoff_calls <- succ counters.cutoff_calls

type ('node, 'next) access = {
  queued : 'node -> bool;
  set_queued : 'node -> bool -> unit;
  previous : 'node -> 'next option;
  set_previous : 'node -> 'next option -> unit;
  next : 'node -> 'next option;
  set_next : 'node -> 'next option -> unit;
  attempt_local : 'node -> bool;
  set_attempt_local : 'node -> bool -> unit;
  attempt_removed : 'node -> bool;
  set_attempt_removed : 'node -> bool -> unit;
  pack : 'node -> 'next;
  unpack : 'next -> 'node;
}

type 'next t = {
  counters : counters;
  mutable head : 'next option;
  mutable tail : 'next option;
  mutable active : 'next attempt option;
}

and 'next attempt = {
  mutable committed_cursor : 'next option;
  mutable local_head : 'next option;
  mutable local_tail : 'next option;
  mutable local_nodes : 'next list;
  mutable local_work : int;
}

let access ~queued ~set_queued ~previous ~set_previous ~next ~set_next
    ~attempt_local ~set_attempt_local ~attempt_removed ~set_attempt_removed
    ~pack ~unpack =
  {
    queued;
    set_queued;
    previous;
    set_previous;
    next;
    set_next;
    attempt_local;
    set_attempt_local;
    attempt_removed;
    set_attempt_removed;
    pack;
    unpack;
  }

let create counters = { counters; head = None; tail = None; active = None }
let is_empty scheduler = Option.is_none scheduler.head
let attempt_active scheduler = Option.is_some scheduler.active

let begin_attempt scheduler =
  match scheduler.active with
  | Some _ -> invalid_arg "Eta_signal_scheduler.begin_attempt: already active"
  | None ->
      scheduler.active <-
        Some
          {
            committed_cursor = scheduler.head;
            local_head = None;
            local_tail = None;
            local_nodes = [];
            local_work = 0;
          }

let admit scheduler access node =
  note_admission scheduler.counters;
  if access.queued node then false
  else (
    access.set_queued node true;
    access.set_next node None;
    let packed = access.pack node in
    (match scheduler.active with
    | None ->
        access.set_attempt_local node false;
        access.set_attempt_removed node false;
        access.set_previous node scheduler.tail;
        (match scheduler.tail with
        | None -> scheduler.head <- Some packed
        | Some tail -> access.set_next (access.unpack tail) (Some packed));
        scheduler.tail <- Some packed
    | Some attempt ->
        access.set_attempt_local node true;
        access.set_attempt_removed node false;
        access.set_previous node attempt.local_tail;
        (match attempt.local_tail with
        | None -> attempt.local_head <- Some packed
        | Some tail -> access.set_next (access.unpack tail) (Some packed));
        attempt.local_tail <- Some packed;
        attempt.local_nodes <- packed :: attempt.local_nodes;
        attempt.local_work <- attempt.local_work + 1);
    true)

let claim_committed scheduler access =
  match scheduler.head with
  | None -> None
  | Some packed ->
      let node = access.unpack packed in
      scheduler.head <- access.next node;
      (match scheduler.head with
      | None -> scheduler.tail <- None
      | Some head -> access.set_previous (access.unpack head) None);
      access.set_previous node None;
      access.set_next node None;
      access.set_queued node false;
      note_claim scheduler.counters;
      Some node

let rec claim_attempt scheduler access attempt =
  match attempt.committed_cursor with
  | Some packed ->
      let node = access.unpack packed in
      attempt.committed_cursor <- access.next node;
      if access.attempt_removed node then claim_attempt scheduler access attempt
      else (
        note_claim scheduler.counters;
        Some node)
  | None -> (
      match attempt.local_head with
      | None -> None
      | Some packed ->
          let node = access.unpack packed in
          attempt.local_head <- access.next node;
          (match attempt.local_head with
          | None -> attempt.local_tail <- None
          | Some head -> access.set_previous (access.unpack head) None);
          access.set_previous node None;
          access.set_next node None;
          access.set_queued node false;
          access.set_attempt_local node false;
          note_claim scheduler.counters;
          Some node)

let claim scheduler access =
  match scheduler.active with
  | None -> claim_committed scheduler access
  | Some attempt -> claim_attempt scheduler access attempt

let remove scheduler access node =
  if not (access.queued node) then false
  else
    let previous = access.previous node in
    let next = access.next node in
    match scheduler.active with
    | Some attempt when access.attempt_local node ->
        (match previous with
        | None -> attempt.local_head <- next
        | Some previous ->
            access.set_next (access.unpack previous) next);
        (match next with
        | None -> attempt.local_tail <- previous
        | Some next ->
            access.set_previous (access.unpack next) previous);
        access.set_previous node None;
        access.set_next node None;
        access.set_queued node false;
        access.set_attempt_local node false;
        true
    | Some _ ->
        if access.attempt_removed node then false
        else (
          access.set_attempt_removed node true;
          true)
    | None ->
        (match previous with
        | None -> scheduler.head <- next
        | Some previous ->
            access.set_next (access.unpack previous) next);
        (match next with
        | None -> scheduler.tail <- previous
        | Some next ->
            access.set_previous (access.unpack next) previous);
        access.set_previous node None;
        access.set_next node None;
        access.set_queued node false;
        access.set_attempt_local node false;
        access.set_attempt_removed node false;
        true

let clear_node access packed =
  let node = access.unpack packed in
  access.set_previous node None;
  access.set_next node None;
  access.set_queued node false;
  access.set_attempt_local node false;
  access.set_attempt_removed node false

let finish_attempt scheduler access ~commit =
  match scheduler.active with
  | None -> invalid_arg "Eta_signal_scheduler.finish_attempt: no active attempt"
  | Some attempt ->
      let local_work = attempt.local_work in
      List.iter (clear_node access) attempt.local_nodes;
      let committed_work =
        if commit then (
          let count = ref 0 in
          let cursor = ref scheduler.head in
          while Option.is_some !cursor do
            let packed = Option.get !cursor in
            cursor := access.next (access.unpack packed);
            clear_node access packed;
            incr count
          done;
          scheduler.head <- None;
          scheduler.tail <- None;
          !count)
        else (
          let cursor = ref scheduler.head in
          while Option.is_some !cursor do
            let packed = Option.get !cursor in
            let node = access.unpack packed in
            cursor := access.next node;
            access.set_attempt_removed node false
          done;
          0)
      in
      scheduler.active <- None;
      committed_work + local_work

let commit_attempt scheduler access =
  finish_attempt scheduler access ~commit:true

let rollback_attempt scheduler access =
  finish_attempt scheduler access ~commit:false
