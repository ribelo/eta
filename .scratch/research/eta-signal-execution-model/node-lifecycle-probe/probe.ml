(* PROTOTYPE: dense node lifecycle and the accepted static rollback kernel. *)

exception Injected_failure
exception Generation_overflow
exception Pass_identity_exhausted
exception Wrong_phase of string

type phase = Idle | Active | Cleanup_pending

type handle = { slot : int; generation : int }

type lifecycle_counts = {
  mutable commit_steps : int;
  mutable cleanup_calls : int;
  mutable cleanup_visits : int;
  mutable rollback_visits : int;
  mutable lifecycle_entries : int;
}

type node = {
  mutable value : int;
  mutable prev : int;
  mutable written_at : int;
  mutable alive : bool;
}

type slot = {
  mutable generation : int;
  mutable node : node option;
}

type topology_action =
  | Retired of int * node
  | Created of int

type arena = {
  mutable slots : slot array;
  mutable slot_count : int;
  mutable free : int array;
  mutable free_length : int;
  mutable quarantine : int array;
  mutable quarantine_length : int;
  mutable actions : topology_action array;
  mutable action_length : int;
  mutable journal : int array;
  mutable journal_length : int;
  mutable pass : int;
  mutable phase : phase;
  counts : lifecycle_counts;
}

let failf format = Printf.ksprintf failwith format

let assert_int label expected actual =
  if expected <> actual then
    failf "%s: expected %d, observed %d" label expected actual

let assert_bool label expected actual =
  if expected <> actual then
    failf "%s: expected %b, observed %b" label expected actual

let assert_phase label expected actual =
  if expected <> actual then failwith (label ^ ": observed wrong phase")

let expect_wrong_phase label f =
  match f () with
  | () -> failwith (label ^ ": operation did not reject its phase")
  | exception Wrong_phase _ -> ()

let grow_int array =
  let next = Array.make (max 1 (Array.length array * 2)) 0 in
  Array.blit array 0 next 0 (Array.length array);
  next

let grow_actions array =
  let next =
    Array.make (max 1 (Array.length array * 2)) (Created 0)
  in
  Array.blit array 0 next 0 (Array.length array);
  next

let create_arena () =
  {
    slots = [||];
    slot_count = 0;
    free = Array.make 4 0;
    free_length = 0;
    quarantine = Array.make 4 0;
    quarantine_length = 0;
    actions = Array.make 4 (Created 0);
    action_length = 0;
    journal = Array.make 16 0;
    journal_length = 0;
    pass = 0;
    phase = Idle;
    counts =
      {
        commit_steps = 0;
        cleanup_calls = 0;
        cleanup_visits = 0;
        rollback_visits = 0;
        lifecycle_entries = 0;
      };
  }

let ensure_slot_capacity arena seed =
  if arena.slot_count = Array.length arena.slots then (
    let next_length = max 1 (arena.slot_count * 2) in
    let next = Array.make next_length seed in
    Array.blit arena.slots 0 next 0 arena.slot_count;
    arena.slots <- next)

let append_slot arena value =
  let node = { value; prev = value; written_at = -1; alive = true } in
  let entry = { generation = 0; node = Some node } in
  ensure_slot_capacity arena entry;
  let index = arena.slot_count in
  arena.slots.(index) <- entry;
  arena.slot_count <- index + 1;
  { slot = index; generation = 0 }

let push_free arena index =
  if arena.free_length = Array.length arena.free then
    arena.free <- grow_int arena.free;
  arena.free.(arena.free_length) <- index;
  arena.free_length <- arena.free_length + 1

let push_quarantine arena index =
  if arena.quarantine_length = Array.length arena.quarantine then
    arena.quarantine <- grow_int arena.quarantine;
  arena.quarantine.(arena.quarantine_length) <- index;
  arena.quarantine_length <- arena.quarantine_length + 1

let push_action arena action =
  if arena.action_length = Array.length arena.actions then
    arena.actions <- grow_actions arena.actions;
  arena.actions.(arena.action_length) <- action;
  arena.action_length <- arena.action_length + 1;
  arena.counts.lifecycle_entries <- arena.counts.lifecycle_entries + 1

let resolve arena handle =
  if handle.slot < 0 || handle.slot >= arena.slot_count then None
  else
    let entry = arena.slots.(handle.slot) in
    if entry.generation <> handle.generation then None else entry.node

let value_exn arena handle =
  match resolve arena handle with
  | Some node -> node.value
  | None -> invalid_arg "stale node handle"

let allocate arena value =
  if arena.free_length = 0 then append_slot arena value
  else
    let free_index = arena.free_length - 1 in
    let index = arena.free.(free_index) in
    let entry = arena.slots.(index) in
    if entry.generation = max_int then raise Generation_overflow;
    let generation = entry.generation + 1 in
    let node = { value; prev = value; written_at = -1; alive = true } in
    entry.generation <- generation;
    entry.node <- Some node;
    arena.free_length <- free_index;
    { slot = index; generation }

let create_quiescent arena value =
  if arena.phase <> Idle then
    raise (Wrong_phase "quiescent creation requires idle");
  allocate arena value

let begin_pass arena =
  if arena.phase <> Idle then raise (Wrong_phase "begin requires idle");
  if arena.pass = max_int then raise Pass_identity_exhausted;
  arena.phase <- Active;
  arena.action_length <- 0;
  arena.quarantine_length <- 0

let create_tentative arena value =
  if arena.phase <> Active then
    raise (Wrong_phase "tentative creation requires active pass");
  let handle = allocate arena value in
  push_action arena (Created handle.slot);
  handle

let retire arena handle =
  if arena.phase <> Active then
    raise (Wrong_phase "retirement requires active pass");
  match resolve arena handle with
  | None -> invalid_arg "stale node handle"
  | Some node ->
      node.alive <- false;
      arena.slots.(handle.slot).node <- None;
      push_quarantine arena handle.slot;
      push_action arena (Retired (handle.slot, node))

let touch arena handle candidate =
  if arena.phase <> Active then
    raise (Wrong_phase "write requires active pass");
  match resolve arena handle with
  | None -> invalid_arg "stale node handle"
  | Some node ->
      if node.written_at <> arena.pass then (
        if arena.journal_length = Array.length arena.journal then
          arena.journal <- grow_int arena.journal;
        node.prev <- node.value;
        node.written_at <- arena.pass;
        arena.journal.(arena.journal_length) <- handle.slot;
        arena.journal_length <- arena.journal_length + 1);
      node.value <- candidate

let commit arena =
  if arena.phase <> Active then raise (Wrong_phase "commit requires active pass");
  (* The publication point has three fixed scalar assignments and no node loop. *)
  arena.journal_length <- 0;
  arena.pass <- arena.pass + 1;
  arena.phase <-
    (if arena.action_length = 0 then Idle else Cleanup_pending);
  arena.counts.commit_steps <- arena.counts.commit_steps + 3

let cleanup arena =
  if arena.phase <> Cleanup_pending then
    raise (Wrong_phase "cleanup requires pending lifecycle work");
  arena.counts.cleanup_calls <- arena.counts.cleanup_calls + 1;
  for index = 0 to arena.action_length - 1 do
    (match arena.actions.(index) with
    | Retired (slot_index, _) -> push_free arena slot_index
    | Created _ -> ());
    arena.actions.(index) <- Created 0;
    arena.counts.cleanup_visits <- arena.counts.cleanup_visits + 1
  done;
  arena.action_length <- 0;
  arena.quarantine_length <- 0;
  arena.phase <- Idle

let rollback arena =
  if arena.phase <> Active then
    raise (Wrong_phase "rollback requires active pass");
  (* Phase one restores slots that retirement removed. *)
  for index = arena.action_length - 1 downto 0 do
    arena.counts.rollback_visits <- arena.counts.rollback_visits + 1;
    (match arena.actions.(index) with
    | Retired (slot_index, node) ->
        node.alive <- true;
        arena.slots.(slot_index).node <- Some node
    | Created _ -> ())
  done;
  (* Phase two requires every active journal slot to resolve. *)
  for index = arena.journal_length - 1 downto 0 do
    arena.counts.rollback_visits <- arena.counts.rollback_visits + 1;
    let slot = arena.slots.(arena.journal.(index)) in
    (match slot.node with
    | Some node ->
        node.value <- node.prev;
        node.written_at <- -1
    | None -> failwith "active value journal resolved to an empty slot")
  done;
  arena.journal_length <- 0;
  (* Phase three discards tentative creations and clears retained pointers. *)
  for index = arena.action_length - 1 downto 0 do
    arena.counts.rollback_visits <- arena.counts.rollback_visits + 1;
    (match arena.actions.(index) with
    | Created slot_index ->
        let entry = arena.slots.(slot_index) in
        (match entry.node with
        | Some node -> node.alive <- false
        | None -> failwith "tentative creation resolved to an empty slot");
        entry.node <- None;
        push_free arena slot_index
    | Retired _ -> ());
    arena.actions.(index) <- Created 0
  done;
  arena.action_length <- 0;
  arena.quarantine_length <- 0;
  arena.pass <- arena.pass + 1;
  arena.phase <- Idle

let reset_lifecycle_counts arena =
  arena.counts.commit_steps <- 0;
  arena.counts.cleanup_calls <- 0;
  arena.counts.cleanup_visits <- 0;
  arena.counts.rollback_visits <- 0;
  arena.counts.lifecycle_entries <- 0

let live_count arena =
  let count = ref 0 in
  for index = 0 to arena.slot_count - 1 do
    if arena.slots.(index).node <> None then incr count
  done;
  !count

(* Candidate B static path: direct unary propagation and sparse integer undo. *)
module Static = struct
  type graph = {
    arena : arena;
    source : node;
    source_handle : handle;
    mutable nodes : node array;
    mutable accepted : int;
    depth : int;
    cutoff : bool;
    mutable pending_head : node option;
    mutable pending_tail : node option;
  }

  let[@inline never] queue_link node = Some node

  let make ~depth ~cutoff =
    let arena = create_arena () in
    let source_handle = create_quiescent arena 0 in
    let source =
      match resolve arena source_handle with Some node -> node | None -> assert false
    in
    let node_count = if cutoff then depth + 1 else depth in
    let nodes =
      Array.init node_count (fun index ->
          let value = if cutoff then index else index + 1 in
          let handle = create_quiescent arena value in
          match resolve arena handle with Some node -> node | None -> assert false)
    in
    {
      arena;
      source;
      source_handle;
      nodes;
      accepted = 0;
      depth;
      cutoff;
      pending_head = None;
      pending_tail = None;
    }

  let set graph value =
    graph.accepted <- value;
    graph.pending_head <- queue_link graph.source;
    graph.pending_tail <- queue_link graph.source

  let stabilize graph =
    begin_pass graph.arena;
    if graph.pending_head <> None && graph.source.value <> graph.accepted then
      touch graph.arena graph.source_handle graph.accepted;
    if not graph.cutoff then (
      let current = ref graph.accepted in
      for index = 0 to graph.depth - 1 do
        incr current;
        let entry = graph.arena.slots.(index + 1) in
        touch graph.arena
          { slot = index + 1; generation = entry.generation }
          !current
      done);
    commit graph.arena;
    if graph.arena.action_length <> 0 then cleanup graph.arena;
    graph.pending_head <- None;
    graph.pending_tail <- None;
    Ok ()

  let value graph =
    if graph.depth = 0 then graph.source.value
    else graph.nodes.(Array.length graph.nodes - 1).value
end

let check_stale_handle () =
  let arena = create_arena () in
  let old = create_quiescent arena 10 in
  begin_pass arena;
  retire arena old;
  commit arena;
  cleanup arena;
  let replacement = create_quiescent arena 20 in
  assert_int "stale handle reused slot" old.slot replacement.slot;
  assert_bool "stale handle cannot resolve" true (resolve arena old = None);
  assert_int "replacement value" 20 (value_exn arena replacement)

let check_stale_journal_prefix () =
  let arena = create_arena () in
  let old = create_quiescent arena 10 in
  begin_pass arena;
  touch arena old 11;
  commit arena;
  assert_int "inactive journal length" 0 arena.journal_length;
  begin_pass arena;
  retire arena old;
  commit arena;
  cleanup arena;
  let replacement = create_quiescent arena 20 in
  assert_int "stale prefix replacement slot" old.slot replacement.slot;
  let replacement_node = Option.get (resolve arena replacement) in
  replacement_node.prev <- -777;
  begin_pass arena;
  rollback arena;
  assert_int "inactive prefix replacement value" 20
    (value_exn arena replacement);
  begin_pass arena;
  touch arena replacement 21;
  assert_int "active journal overwrote stale slot" replacement.slot
    arena.journal.(0);
  rollback arena;
  assert_int "replacement rollback value" 20 (value_exn arena replacement)

let check_failed_retirement () =
  let arena = create_arena () in
  let original = create_quiescent arena 17 in
  begin_pass arena;
  retire arena original;
  rollback arena;
  assert_int "failed retirement identity" 17 (value_exn arena original);
  assert_int "failed retirement free count" 0 arena.free_length

let check_failed_creation () =
  let arena = create_arena () in
  begin_pass arena;
  let tentative = create_tentative arena 30 in
  rollback arena;
  assert_bool "failed tentative handle stale" true
    (resolve arena tentative = None);
  let replacement = create_quiescent arena 31 in
  assert_int "failed tentative slot reused" tentative.slot replacement.slot;
  assert_int "failed tentative generation advanced"
    (tentative.generation + 1) replacement.generation

let check_stale_tentative_after_reuse () =
  let arena = create_arena () in
  begin_pass arena;
  let stale = create_tentative arena 30 in
  rollback arena;
  begin_pass arena;
  let replacement = create_tentative arena 31 in
  assert_int "stale tentative reused slot" stale.slot replacement.slot;
  assert_int "stale tentative replacement generation"
    (stale.generation + 1) replacement.generation;
  assert_bool "stale tentative cannot resolve replacement" true
    (resolve arena stale = None);
  commit arena;
  cleanup arena;
  assert_int "tentative replacement value" 31
    (value_exn arena replacement)

let check_touched_tentative_rollback () =
  let arena = create_arena () in
  reset_lifecycle_counts arena;
  begin_pass arena;
  let tentative = create_tentative arena 40 in
  touch arena tentative 41;
  rollback arena;
  assert_bool "touched tentative handle stale" true
    (resolve arena tentative = None);
  assert_int "touched tentative rollback visits" 3
    arena.counts.rollback_visits;
  let replacement = create_quiescent arena 50 in
  assert_int "touched tentative replacement slot" tentative.slot
    replacement.slot;
  assert_int "touched tentative replacement generation"
    (tentative.generation + 1) replacement.generation;
  assert_int "touched tentative replacement value" 50
    (value_exn arena replacement);
  begin_pass arena;
  touch arena replacement 51;
  rollback arena;
  assert_int "touched tentative replacement rollback" 50
    (value_exn arena replacement)

let check_missing_journal_slot_fails () =
  let arena = create_arena () in
  let handle = create_quiescent arena 60 in
  begin_pass arena;
  touch arena handle 61;
  arena.slots.(handle.slot).node <- None;
  let raised =
    match rollback arena with
    | () -> false
    | exception Failure message ->
        message = "active value journal resolved to an empty slot"
  in
  assert_bool "missing active journal slot fails loudly" true raised

let check_no_same_pass_reuse () =
  let arena = create_arena () in
  let old = create_quiescent arena 1 in
  begin_pass arena;
  retire arena old;
  let fresh = create_tentative arena 2 in
  if old.slot = fresh.slot then failwith "retired slot reused in active pass";
  rollback arena;
  assert_int "same-pass rollback original" 1 (value_exn arena old)

let check_mixed_failed_pass () =
  let arena = create_arena () in
  let touched = create_quiescent arena 10 in
  begin_pass arena;
  touch arena touched 11;
  retire arena touched;
  let tentative = create_tentative arena 30 in
  rollback arena;
  assert_int "mixed rollback touched value" 10 (value_exn arena touched);
  assert_bool "mixed rollback tentative stale" true
    (resolve arena tentative = None);
  let replacement = create_quiescent arena 40 in
  assert_int "mixed rollback reused tentative slot" tentative.slot replacement.slot

let check_exact_commit_steps () =
  List.iter
    (fun action_count ->
      let arena = create_arena () in
      let nodes =
        Array.init action_count (fun index -> create_quiescent arena index)
      in
      reset_lifecycle_counts arena;
      begin_pass arena;
      Array.iter (retire arena) nodes;
      let before = arena.counts.commit_steps in
      commit arena;
      assert_int "fixed commit-step delta" 3
        (arena.counts.commit_steps - before);
      assert_int "cleanup visits before cleanup" 0
        arena.counts.cleanup_visits;
      assert_int "cleanup calls before cleanup" 0
        arena.counts.cleanup_calls;
      if action_count = 0 then
        assert_phase "zero-action commit phase" Idle arena.phase
      else (
        assert_phase "lifecycle commit phase" Cleanup_pending arena.phase;
        cleanup arena;
        assert_int "cleanup calls" 1 arena.counts.cleanup_calls;
        assert_int "cleanup visits" action_count
          arena.counts.cleanup_visits))
    [ 0; 1; 4; 1_000 ]

let check_cleanup_phase () =
  let arena = create_arena () in
  expect_wrong_phase "idle cleanup" (fun () -> cleanup arena);
  assert_phase "idle cleanup retained phase" Idle arena.phase;
  begin_pass arena;
  let active_tentative = create_tentative arena 69 in
  expect_wrong_phase "active cleanup" (fun () -> cleanup arena);
  assert_phase "active cleanup retained phase" Active arena.phase;
  assert_int "active cleanup retained action" 1 arena.action_length;
  assert_int "active cleanup retained tentative" 69
    (value_exn arena active_tentative);
  rollback arena;

  let old = create_quiescent arena 70 in
  let old_node = Option.get (resolve arena old) in
  let weak = Weak.create 1 in
  Weak.set weak 0 (Some old_node);
  begin_pass arena;
  retire arena old;
  commit arena;
  assert_phase "retirement commit pending" Cleanup_pending arena.phase;
  assert_int "pending action length" 1 arena.action_length;
  assert_int "pending quarantine length" 1 arena.quarantine_length;
  (match arena.actions.(0) with
  | Retired (slot, retained) ->
      assert_int "pending retired slot" old.slot slot;
      if retained != old_node then
        failwith "pending retirement did not retain its node pointer"
  | Created _ -> failwith "pending retirement action changed kind");
  expect_wrong_phase "begin before cleanup" (fun () -> begin_pass arena);
  expect_wrong_phase "allocation before cleanup" (fun () ->
      ignore (create_quiescent arena 71));
  expect_wrong_phase "rollback before cleanup" (fun () -> rollback arena);
  assert_phase "rejected operations retained pending phase" Cleanup_pending
    arena.phase;
  assert_int "rejected operations retained actions" 1 arena.action_length;
  assert_int "rejected operations retained quarantine" 1
    arena.quarantine_length;
  assert_bool "rejected operations retained pointer" true
    (Weak.get weak 0 <> None);
  cleanup arena;
  assert_phase "cleanup returned idle" Idle arena.phase;
  assert_int "cleanup cleared actions" 0 arena.action_length;
  assert_int "cleanup cleared quarantine" 0 arena.quarantine_length;
  let replacement = create_quiescent arena 72 in
  assert_int "post-cleanup slot reuse" old.slot replacement.slot;
  assert_bool "post-cleanup retired handle stale" true
    (resolve arena old = None);
  assert_int "post-cleanup replacement value" 72
    (value_exn arena replacement);
  Gc.full_major ();
  assert_bool "post-cleanup retired pointer released" true
    (Weak.get weak 0 = None);
  assert_int "cleanup phase arena remains live" 1 (live_count arena)

let check_pass_identity_boundaries () =
  let commit_arena = create_arena () in
  let committed = create_quiescent commit_arena 80 in
  commit_arena.pass <- max_int - 1;
  begin_pass commit_arena;
  touch commit_arena committed 81;
  commit commit_arena;
  assert_int "commit boundary pass" max_int commit_arena.pass;
  assert_int "commit boundary value" 81 (value_exn commit_arena committed);
  let before_phase = commit_arena.phase in
  let before_actions = commit_arena.action_length in
  let raised =
    match begin_pass commit_arena with
    | () -> false
    | exception Pass_identity_exhausted -> true
  in
  assert_bool "commit boundary exhaustion" true raised;
  assert_int "commit exhaustion pass unchanged" max_int commit_arena.pass;
  assert_phase "commit exhaustion phase unchanged" before_phase
    commit_arena.phase;
  assert_int "commit exhaustion actions unchanged" before_actions
    commit_arena.action_length;
  assert_int "commit exhaustion journal unchanged" 0
    commit_arena.journal_length;
  assert_int "commit exhaustion quarantine unchanged" 0
    commit_arena.quarantine_length;

  let rollback_arena = create_arena () in
  let restored = create_quiescent rollback_arena 90 in
  rollback_arena.pass <- max_int - 1;
  begin_pass rollback_arena;
  touch rollback_arena restored 91;
  rollback rollback_arena;
  assert_int "rollback boundary pass" max_int rollback_arena.pass;
  assert_int "first-write rollback before exhaustion" 90
    (value_exn rollback_arena restored);
  let raised =
    match begin_pass rollback_arena with
    | () -> false
    | exception Pass_identity_exhausted -> true
  in
  assert_bool "rollback boundary exhaustion" true raised;
  assert_int "rollback exhaustion pass unchanged" max_int
    rollback_arena.pass;
  assert_phase "rollback exhaustion phase unchanged" Idle
    rollback_arena.phase;
  assert_int "rollback exhaustion journal unchanged" 0
    rollback_arena.journal_length;
  assert_int "rollback exhaustion actions unchanged" 0
    rollback_arena.action_length;
  assert_int "rollback exhaustion quarantine unchanged" 0
    rollback_arena.quarantine_length

let successful_tentative_churn ~live ~churn =
  let arena = create_arena () in
  let handles = Array.init live (fun index -> create_quiescent arena index) in
  for index = 0 to churn - 1 do
    let position = index mod live in
    begin_pass arena;
    retire arena handles.(position);
    let replacement = create_tentative arena index in
    commit arena;
    cleanup arena;
    handles.(position) <- replacement
  done;
  assert_int "successful tentative churn live count" live
    (live_count arena);
  if arena.slot_count > live + 1 then
    failf
      "successful tentative churn retained %d slots for %d live nodes"
      arena.slot_count live

let failed_tentative_churn ~live ~churn =
  let arena = create_arena () in
  let _handles =
    Array.init live (fun index -> create_quiescent arena index)
  in
  let previous = ref None in
  for index = 0 to churn - 1 do
    begin_pass arena;
    let tentative = create_tentative arena index in
    (match !previous with
    | Some stale ->
        assert_bool "failed churn stale tentative" true
          (resolve arena stale = None)
    | None -> ());
    rollback arena;
    assert_bool "failed churn tentative after rollback" true
      (resolve arena tentative = None);
    previous := Some tentative
  done;
  assert_int "failed tentative churn live count" live (live_count arena);
  if arena.slot_count > live + 1 then
    failf "failed tentative churn retained %d slots for %d live nodes"
      arena.slot_count live

let check_churn () =
  List.iter
    (fun live ->
      successful_tentative_churn ~live ~churn:1_024;
      successful_tentative_churn ~live ~churn:100_000;
      failed_tentative_churn ~live ~churn:1_024;
      failed_tentative_churn ~live ~churn:100_000)
    [ 1; 10; 100 ]

let check_generation_overflow () =
  let arena = create_arena () in
  let handle = create_quiescent arena 9 in
  begin_pass arena;
  retire arena handle;
  commit arena;
  cleanup arena;
  let entry = arena.slots.(handle.slot) in
  entry.generation <- max_int;
  let before_free = arena.free_length in
  let raised =
    match create_quiescent arena 10 with
    | _ -> false
    | exception Generation_overflow -> true
  in
  assert_bool "generation overflow raised" true raised;
  assert_int "overflow generation unchanged" max_int entry.generation;
  assert_int "overflow free list unchanged" before_free arena.free_length;
  assert_bool "overflow slot empty" true (entry.node = None);
  begin_pass arena;
  let before_actions = arena.action_length in
  let raised =
    match create_tentative arena 11 with
    | _ -> false
    | exception Generation_overflow -> true
  in
  assert_bool "tentative generation overflow raised" true raised;
  assert_int "tentative overflow generation unchanged" max_int
    entry.generation;
  assert_int "tentative overflow free list unchanged" before_free
    arena.free_length;
  assert_int "tentative overflow actions unchanged" before_actions
    arena.action_length;
  assert_bool "tentative overflow slot empty" true (entry.node = None);
  rollback arena

module Monotonic = struct
  type t = {
    mutable slots : bool array;
    mutable next : int;
  }

  let create live = { slots = Array.make live true; next = live - 1 }

  let churn arena operations =
    let live_slot = ref 0 in
    for _ = 1 to operations do
      arena.slots.(!live_slot) <- false;
      arena.next <- arena.next + 1;
      if arena.next = Array.length arena.slots then (
        let next_slots = Array.make (Array.length arena.slots * 2) false in
        Array.blit arena.slots 0 next_slots 0 (Array.length arena.slots);
        arena.slots <- next_slots);
      arena.slots.(arena.next) <- true;
      live_slot := arena.next
    done

  let retained arena = arena.next + 1
end

module Compacting = struct
  type t = { mutable visits : int }

  let compact arena live =
    let table = Array.make live 1 in
    for index = 0 to Array.length table - 1 do
      ignore table.(index);
      arena.visits <- arena.visits + 1
    done
end

let check_counterexamples () =
  let live = 10 in
  let executable_churn = 100_000 in
  let monotonic = Monotonic.create live in
  Monotonic.churn monotonic executable_churn;
  let observed = Monotonic.retained monotonic in
  let expected = live + executable_churn in
  assert_int "candidate A retained-slot formula" expected observed;
  let monotonic_retained = observed in
  Printf.printf
    "A counterexample: live=%d churn=%d retained_slots=%d expected_bound=%d\n%!"
    live executable_churn monotonic_retained live;
  if monotonic_retained <= live then
    failwith "candidate A did not show unbounded retention";
  let affected = 1 in
  let arena_live = 100_000 in
  let compacting = Compacting.{ visits = 0 } in
  Compacting.compact compacting arena_live;
  let compaction_visits = compacting.visits in
  assert_int "candidate C full-table visits" arena_live compaction_visits;
  Printf.printf
    "C counterexample: live=%d affected=%d compaction_visits=%d\n%!"
    arena_live affected compaction_visits;
  if compaction_visits <= affected then
    failwith "candidate C did not show a full-table scan"

let check_immediates_and_quiescence () =
  let arena = create_arena () in
  let handle = create_quiescent arena 1 in
  begin_pass arena;
  touch arena handle 2;
  if not (Obj.is_int (Obj.repr arena.journal.(0))) then
    failwith "journal entry is not an immediate integer";
  commit arena;
  assert_phase "quiescent phase" Idle arena.phase;
  assert_int "quiescent journal" 0 arena.journal_length;
  assert_int "quiescent quarantine" 0 arena.quarantine_length;
  assert_int "quiescent actions" 0 arena.action_length

let check_static () =
  List.iter
    (fun depth ->
      let graph = Static.make ~depth ~cutoff:false in
      reset_lifecycle_counts graph.arena;
      Static.set graph 1;
      ignore (Static.stabilize graph);
      assert_int "static value" (depth + 1) (Static.value graph);
      assert_int "static lifecycle entries" 0
        graph.arena.counts.lifecycle_entries;
      assert_int "static cleanup calls" 0 graph.arena.counts.cleanup_calls;
      assert_int "static fixed commit steps" 3
        graph.arena.counts.commit_steps)
    [ 1; 10; 100 ];
  let graph = Static.make ~depth:10 ~cutoff:true in
  reset_lifecycle_counts graph.arena;
  Static.set graph 1;
  ignore (Static.stabilize graph);
  assert_int "static cutoff value" 10 (Static.value graph);
  assert_int "cutoff lifecycle entries" 0
    graph.arena.counts.lifecycle_entries;
  assert_int "cutoff cleanup calls" 0 graph.arena.counts.cleanup_calls;
  assert_int "cutoff fixed commit steps" 3 graph.arena.counts.commit_steps

let check_weak_retention () =
  let arena = create_arena () in
  let weak = Weak.create 1 in
  let retire_local () =
    let handle = create_quiescent arena 99 in
    let node = Option.get (resolve arena handle) in
    Weak.set weak 0 (Some node);
    begin_pass arena;
    retire arena handle;
    commit arena;
    cleanup arena
  in
  retire_local ();
  Gc.full_major ();
  Gc.compact ();
  assert_bool "retired node weak retention" true (Weak.get weak 0 = None);
  assert_int "weak check arena remains live" 1 arena.slot_count

let run_checks () =
  check_stale_handle ();
  check_stale_journal_prefix ();
  check_failed_retirement ();
  check_failed_creation ();
  check_stale_tentative_after_reuse ();
  check_touched_tentative_rollback ();
  check_missing_journal_slot_fails ();
  check_no_same_pass_reuse ();
  check_mixed_failed_pass ();
  check_exact_commit_steps ();
  check_cleanup_phase ();
  check_pass_identity_boundaries ();
  check_churn ();
  check_generation_overflow ();
  check_counterexamples ();
  check_immediates_and_quiescence ();
  check_static ();
  check_weak_retention ();
  Printf.printf "all correctness checks passed\n%!"

type workload = {
  name : string;
  graph_size : int;
  run_batch : int -> unit;
  check : unit -> unit;
}

let static_changed depth =
  let graph = Static.make ~depth ~cutoff:false in
  ignore (Static.stabilize graph);
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Static.set graph !next;
      ignore (Static.stabilize graph)
    done
  in
  {
    name = Printf.sprintf "b.changed.depth_%d" depth;
    graph_size = depth + 1;
    run_batch;
    check = (fun () -> assert_int "static workload" (!next + depth) (Static.value graph));
  }

let static_cutoff depth =
  let graph = Static.make ~depth ~cutoff:true in
  ignore (Static.stabilize graph);
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Static.set graph !next;
      ignore (Static.stabilize graph)
    done
  in
  {
    name = Printf.sprintf "b.cutoff.depth_%d" depth;
    graph_size = depth + 2;
    run_batch;
    check = (fun () -> assert_int "cutoff workload" depth (Static.value graph));
  }

let incremental_changed depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = chain depth (Incr.Var.watch source) in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done
  in
  {
    name = Printf.sprintf "incremental.raw.changed.depth_%d" depth;
    graph_size = depth + 1;
    run_batch;
    check =
      (fun () ->
        assert_int "Incremental changed" (!next + depth)
          (Incr.Observer.value_exn observer));
  }

let incremental_cutoff depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let constant = Incr.map (Incr.Var.watch source) ~f:(fun _ -> 0) in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = chain depth constant in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done
  in
  {
    name = Printf.sprintf "incremental.raw.cutoff.depth_%d" depth;
    graph_size = depth + 2;
    run_batch;
    check =
      (fun () ->
        assert_int "Incremental cutoff" depth
          (Incr.Observer.value_exn observer));
  }

let lifecycle_workload kind =
  let arena = create_arena () in
  let handles = Array.init 8 (fun index -> create_quiescent arena index) in
  (match kind with
  | `Reuse ->
      let seed = create_quiescent arena 8 in
      begin_pass arena;
      retire arena seed;
      commit arena;
      cleanup arena
  | `Create | `Retire | `Rollback -> ());
  let cursor = ref 0 in
  let run_one () =
    let index = !cursor land 7 in
    (match kind with
    | `Create ->
        begin_pass arena;
        let replacement = create_tentative arena index in
        retire arena handles.(index);
        commit arena;
        cleanup arena;
        handles.(index) <- replacement
    | `Retire ->
        begin_pass arena;
        retire arena handles.(index);
        commit arena;
        cleanup arena;
        handles.(index) <- create_quiescent arena index
    | `Reuse ->
        let replacement = create_quiescent arena index in
        begin_pass arena;
        retire arena replacement;
        commit arena;
        cleanup arena
    | `Rollback ->
        begin_pass arena;
        retire arena handles.(index);
        rollback arena);
    incr cursor
  in
  let run_batch operations = for _ = 1 to operations do run_one () done in
  let suffix =
    match kind with
    | `Create -> "create"
    | `Retire -> "retire_cleanup"
    | `Reuse -> "reuse"
    | `Rollback -> "failed_retire_rollback"
  in
  {
    name = "b.lifecycle." ^ suffix ^ ".graph_8";
    graph_size = 8;
    run_batch;
    check =
      (fun () ->
        assert_int "lifecycle workload live count" 8 (live_count arena);
        if arena.slot_count > 9 then
          failf "lifecycle workload retained %d slots" arena.slot_count;
        assert_phase "lifecycle workload quiescent" Idle arena.phase);
  }

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run_batch operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure ~samples workload =
  let operations = calibrate workload 1 in
  workload.run_batch operations;
  workload.check ();
  Gc.full_major ();
  for sample = 1 to samples do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run_batch operations;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major = Gc.counters () in
    workload.check ();
    let count = float_of_int operations in
    let wall_ns = ((stopped -. started) *. 1e9) /. count in
    let words =
      ((after_minor -. before_minor)
       +. (after_major -. before_major)
       -. (after_promoted -. before_promoted))
      /. count
    in
    Printf.printf "%s,%d,%d,%d,%.6f,%.6f\n%!" workload.name
      workload.graph_size operations sample wall_ns words
  done

let workloads =
  [
    "b.changed.depth_1", (fun () -> static_changed 1);
    "b.changed.depth_10", (fun () -> static_changed 10);
    "b.changed.depth_100", (fun () -> static_changed 100);
    "b.cutoff.depth_10", (fun () -> static_cutoff 10);
    "incremental.raw.changed.depth_1", (fun () -> incremental_changed 1);
    "incremental.raw.changed.depth_10", (fun () -> incremental_changed 10);
    "incremental.raw.changed.depth_100", (fun () -> incremental_changed 100);
    "incremental.raw.cutoff.depth_10", (fun () -> incremental_cutoff 10);
    "b.lifecycle.create.graph_8", (fun () -> lifecycle_workload `Create);
    "b.lifecycle.retire_cleanup.graph_8", (fun () -> lifecycle_workload `Retire);
    "b.lifecycle.reuse.graph_8", (fun () -> lifecycle_workload `Reuse);
    ( "b.lifecycle.failed_retire_rollback.graph_8",
      fun () -> lifecycle_workload `Rollback );
  ]

let parse_args () =
  let rec loop only samples check = function
    | [] -> only, samples, check
    | "--only" :: name :: rest -> loop (Some name) samples check rest
    | "--samples" :: count :: rest ->
        loop only (int_of_string count) check rest
    | "--check" :: rest -> loop only samples true rest
    | argument :: _ -> invalid_arg ("unknown argument: " ^ argument)
  in
  loop None 9 false (List.tl (Array.to_list Sys.argv))

let () =
  let only, samples, check = parse_args () in
  if check then run_checks ()
  else
    match only with
    | None -> invalid_arg "use --check or --only NAME"
    | Some selected ->
        let workload =
          match List.assoc_opt selected workloads with
          | Some make -> make ()
          | None -> invalid_arg "unknown workload"
        in
        Printf.printf
          "name,graph_size,operations,sample,wall_ns,allocated_words\n%!";
        measure ~samples workload
