(* PROTOTYPE: owner-local capsules for dynamic Signal topology. *)

module Int_map = Map.Make (Int)

exception Wrong_phase of string
exception Injected_failure

type phase = Idle | Active | Cleanup_pending

type counts = {
  mutable commit_steps : int;
  mutable cleanup_visits : int;
  mutable rollback_visits : int;
  mutable edge_inserts : int;
  mutable edge_removals : int;
  mutable slot_repairs : int;
  mutable adjacency_searches : int;
  mutable scope_visits : int;
  mutable selected_children : int;
  mutable input_events : int;
}

let counts () =
  {
    commit_steps = 0;
    cleanup_visits = 0;
    rollback_visits = 0;
    edge_inserts = 0;
    edge_removals = 0;
    slot_repairs = 0;
    adjacency_searches = 0;
    scope_visits = 0;
    selected_children = 0;
    input_events = 0;
  }

let reset_counts counts =
  counts.commit_steps <- 0;
  counts.cleanup_visits <- 0;
  counts.rollback_visits <- 0;
  counts.edge_inserts <- 0;
  counts.edge_removals <- 0;
  counts.slot_repairs <- 0;
  counts.adjacency_searches <- 0;
  counts.scope_visits <- 0;
  counts.selected_children <- 0;
  counts.input_events <- 0

type scope = {
  id : int;
  mutable valid : bool;
}

type branch = {
  id : int;
  scope : scope;
  value : int;
  mutable demand : int;
}

type bind_site = {
  mutable phase : phase;
  mutable pass : int;
  mutable next_id : int;
  mutable source : int;
  mutable incumbent : branch;
  mutable candidate : branch option;
  mutable retired : branch option;
  counts : counts;
}

let failf format = Printf.ksprintf failwith format

let assert_int label expected actual =
  if expected <> actual then
    failf "%s: expected %d, observed %d" label expected actual

let assert_bool label expected actual =
  if expected <> actual then
    failf "%s: expected %b, observed %b" label expected actual

let make_scope id = { id; valid = true }
let make_branch id value = { id; scope = make_scope id; value; demand = 0 }

let create_bind source =
  let incumbent = make_branch 0 source in
  incumbent.demand <- 1;
  {
    phase = Idle;
    pass = 0;
    next_id = 1;
    source;
    incumbent;
    candidate = None;
    retired = None;
    counts = counts ();
  }

let bind_begin site =
  if site.phase <> Idle then raise (Wrong_phase "bind begin");
  if site.pass = max_int then failwith "pass identity exhausted";
  site.phase <- Active

let bind_switch site source =
  if site.phase <> Active then raise (Wrong_phase "bind switch");
  if source = site.source then site.incumbent.value
  else
    let fresh = make_branch site.next_id source in
    site.next_id <- site.next_id + 1;
    fresh.demand <- site.incumbent.demand;
    site.incumbent.demand <- 0;
    site.candidate <- Some fresh;
    site.retired <- Some site.incumbent;
    site.counts.edge_removals <- site.counts.edge_removals + 1;
    site.counts.edge_inserts <- site.counts.edge_inserts + 1;
    fresh.value

let bind_effective site =
  match site.phase, site.candidate with
  | Cleanup_pending, Some branch | Active, Some branch -> branch
  | _ -> site.incumbent

let bind_commit site =
  if site.phase <> Active then raise (Wrong_phase "bind commit");
  site.pass <- site.pass + 1;
  site.phase <-
    (match site.candidate with None -> Idle | Some _ -> Cleanup_pending);
  site.counts.commit_steps <- site.counts.commit_steps + 2

let bind_cleanup site =
  if site.phase <> Cleanup_pending then raise (Wrong_phase "bind cleanup");
  let fresh = Option.get site.candidate in
  let old = Option.get site.retired in
  site.source <- fresh.value;
  site.incumbent <- fresh;
  old.scope.valid <- false;
  site.counts.scope_visits <- site.counts.scope_visits + 1;
  site.counts.cleanup_visits <- site.counts.cleanup_visits + 1;
  site.candidate <- None;
  site.retired <- None;
  site.phase <- Idle

let bind_rollback site =
  if site.phase <> Active then raise (Wrong_phase "bind rollback");
  (match site.candidate, site.retired with
   | Some fresh, Some old ->
       old.demand <- fresh.demand;
       fresh.demand <- 0;
       fresh.scope.valid <- false;
       site.counts.rollback_visits <- site.counts.rollback_visits + 1
   | None, None -> ()
   | _ -> failwith "broken bind capsule");
  site.candidate <- None;
  site.retired <- None;
  site.pass <- site.pass + 1;
  site.phase <- Idle

type child = {
  key : int;
  id : int;
  scope : scope;
  mutable data : int;
  mutable staged_data : int option;
  mutable output : int;
  mutable staged_output : int option;
  mutable demand : int;
}

type keyed_site = {
  mutable phase : phase;
  mutable pass : int;
  mutable next_id : int;
  mutable input : int Int_map.t;
  mutable children : child Int_map.t;
  mutable output : int Int_map.t;
  mutable candidate_input : int Int_map.t;
  mutable candidate_children : child Int_map.t;
  mutable candidate_output : int Int_map.t;
  mutable added : child option array;
  mutable added_length : int;
  mutable removed : child option array;
  mutable removed_length : int;
  mutable touched : child option array;
  mutable touched_length : int;
  counts : counts;
}

let grow array =
  let next = Array.make (max 1 (Array.length array * 2)) None in
  Array.blit array 0 next 0 (Array.length array);
  next

let push array length value =
  let array = if length = Array.length array then grow array else array in
  array.(length) <- Some value;
  array

let create_child id key data =
  {
    key;
    id;
    scope = make_scope id;
    data;
    staged_data = None;
    output = data;
    staged_output = None;
    demand = 1;
  }

let create_keyed size =
  let input =
    List.init size (fun key -> key, 0)
    |> List.fold_left (fun map (key, data) -> Int_map.add key data map)
         Int_map.empty
  in
  let children, output, next_id =
    Int_map.fold
      (fun key data (children, output, id) ->
        let child = create_child id key data in
        Int_map.add key child children, Int_map.add key data output, id + 1)
      input (Int_map.empty, Int_map.empty, 0)
  in
  {
    phase = Idle;
    pass = 0;
    next_id;
    input;
    children;
    output;
    candidate_input = input;
    candidate_children = children;
    candidate_output = output;
    added = Array.make 4 None;
    added_length = 0;
    removed = Array.make 4 None;
    removed_length = 0;
    touched = Array.make 4 None;
    touched_length = 0;
    counts = counts ();
  }

let keyed_begin site candidate_input =
  if site.phase <> Idle then raise (Wrong_phase "keyed begin");
  if site.pass = max_int then failwith "pass identity exhausted";
  site.phase <- Active;
  site.candidate_input <- candidate_input;
  site.candidate_children <- site.children;
  site.candidate_output <- site.output;
  site.added_length <- 0;
  site.removed_length <- 0;
  site.touched_length <- 0

let note_touched site child =
  if child.staged_data = None && child.staged_output = None then (
    site.touched <- push site.touched site.touched_length child;
    site.touched_length <- site.touched_length + 1)

let keyed_update_data site key candidate =
  if site.phase <> Active then raise (Wrong_phase "keyed data");
  site.counts.input_events <- site.counts.input_events + 1;
  let child = Int_map.find key site.children in
  if child.data <> candidate then (
    note_touched site child;
    child.staged_data <- Some candidate;
    child.staged_output <- Some candidate;
    site.candidate_output <-
      Int_map.add key candidate site.candidate_output;
    site.counts.selected_children <- site.counts.selected_children + 1)

let keyed_add site key data =
  if site.phase <> Active then raise (Wrong_phase "keyed add");
  site.counts.input_events <- site.counts.input_events + 1;
  let child = create_child site.next_id key data in
  site.next_id <- site.next_id + 1;
  site.candidate_children <- Int_map.add key child site.candidate_children;
  site.candidate_output <- Int_map.add key data site.candidate_output;
  site.added <- push site.added site.added_length child;
  site.added_length <- site.added_length + 1;
  site.counts.edge_inserts <- site.counts.edge_inserts + 1;
  site.counts.selected_children <- site.counts.selected_children + 1

let keyed_remove site key =
  if site.phase <> Active then raise (Wrong_phase "keyed remove");
  site.counts.input_events <- site.counts.input_events + 1;
  let child = Int_map.find key site.children in
  site.candidate_children <- Int_map.remove key site.candidate_children;
  site.candidate_output <- Int_map.remove key site.candidate_output;
  site.removed <- push site.removed site.removed_length child;
  site.removed_length <- site.removed_length + 1;
  site.counts.edge_removals <- site.counts.edge_removals + 1

let keyed_refresh_child site key value =
  if site.phase <> Active then raise (Wrong_phase "keyed child");
  let child = Int_map.find key site.children in
  note_touched site child;
  child.staged_output <- Some value;
  site.candidate_output <- Int_map.add key value site.candidate_output;
  site.counts.selected_children <- site.counts.selected_children + 1

let keyed_commit site =
  if site.phase <> Active then raise (Wrong_phase "keyed commit");
  site.pass <- site.pass + 1;
  site.phase <-
    (if site.added_length + site.removed_length + site.touched_length = 0
     then Idle
     else Cleanup_pending);
  site.counts.commit_steps <- site.counts.commit_steps + 2

let clear_prefix array length =
  for index = 0 to length - 1 do
    array.(index) <- None
  done

let keyed_cleanup site =
  if site.phase <> Cleanup_pending then raise (Wrong_phase "keyed cleanup");
  for index = 0 to site.touched_length - 1 do
    let child = Option.get site.touched.(index) in
    Option.iter (fun data -> child.data <- data) child.staged_data;
    Option.iter (fun output -> child.output <- output) child.staged_output;
    child.staged_data <- None;
    child.staged_output <- None;
    site.counts.cleanup_visits <- site.counts.cleanup_visits + 1
  done;
  for index = 0 to site.removed_length - 1 do
    let child = Option.get site.removed.(index) in
    child.demand <- 0;
    child.scope.valid <- false;
    site.counts.scope_visits <- site.counts.scope_visits + 1;
    site.counts.cleanup_visits <- site.counts.cleanup_visits + 1
  done;
  for _ = 0 to site.added_length - 1 do
    site.counts.cleanup_visits <- site.counts.cleanup_visits + 1
  done;
  site.input <- site.candidate_input;
  site.children <- site.candidate_children;
  site.output <- site.candidate_output;
  clear_prefix site.touched site.touched_length;
  clear_prefix site.removed site.removed_length;
  clear_prefix site.added site.added_length;
  site.touched_length <- 0;
  site.removed_length <- 0;
  site.added_length <- 0;
  site.phase <- Idle

let keyed_rollback site =
  if site.phase <> Active then raise (Wrong_phase "keyed rollback");
  for index = site.touched_length - 1 downto 0 do
    let child = Option.get site.touched.(index) in
    child.staged_data <- None;
    child.staged_output <- None;
    site.counts.rollback_visits <- site.counts.rollback_visits + 1
  done;
  for index = site.removed_length - 1 downto 0 do
    site.counts.rollback_visits <- site.counts.rollback_visits + 1
  done;
  for index = site.added_length - 1 downto 0 do
    let child = Option.get site.added.(index) in
    child.demand <- 0;
    child.scope.valid <- false;
    site.counts.rollback_visits <- site.counts.rollback_visits + 1
  done;
  clear_prefix site.touched site.touched_length;
  clear_prefix site.removed site.removed_length;
  clear_prefix site.added site.added_length;
  site.touched_length <- 0;
  site.removed_length <- 0;
  site.added_length <- 0;
  site.candidate_input <- site.input;
  site.candidate_children <- site.children;
  site.candidate_output <- site.output;
  site.pass <- site.pass + 1;
  site.phase <- Idle

(* Candidate A: a chronological inverse-action journal. *)
module Action_journal = struct
  type action = Restore of branch | Drop of branch | Sentinel

  type t = {
    mutable current : branch;
    mutable actions : action array;
    mutable length : int;
  }

  let create value =
    { current = make_branch 0 value; actions = Array.make 4 Sentinel; length = 0 }

  let switch t value =
    if t.length = Array.length t.actions then (
      let next = Array.make (Array.length t.actions * 2) Sentinel in
      Array.blit t.actions 0 next 0 t.length;
      t.actions <- next);
    let old = t.current in
    let fresh = make_branch (old.id + 1) value in
    t.actions.(t.length) <- Restore old;
    t.length <- t.length + 1;
    t.current <- fresh

  let rollback t =
    for index = t.length - 1 downto 0 do
      match t.actions.(index) with
      | Restore old ->
          t.current.scope.valid <- false;
          t.current <- old;
          t.actions.(index) <- Sentinel
      | Drop _ | Sentinel -> ()
    done;
    t.length <- 0
end

(* Candidate C: immutable whole-topology replacement. *)
let persistent_switch ballast =
  let topology = Array.init ballast Fun.id in
  let next = Array.copy topology in
  if ballast > 0 then next.(ballast - 1) <- next.(ballast - 1) + 1;
  next

let check_bind () =
  let site = create_bind 0 in
  let old = site.incumbent in
  bind_begin site;
  ignore (bind_switch site 1);
  let provisional = bind_effective site in
  assert_int "bind provisional value" 1 provisional.value;
  bind_rollback site;
  assert_bool "bind rollback identity" true (site.incumbent == old);
  assert_bool "bind rollback old scope" true old.scope.valid;
  assert_bool "bind rollback provisional scope" false provisional.scope.valid;
  bind_begin site;
  ignore (bind_switch site 1);
  let fresh = bind_effective site in
  bind_commit site;
  assert_bool "bind commit effective" true (bind_effective site == fresh);
  bind_cleanup site;
  assert_bool "bind cleanup old scope" false old.scope.valid;
  assert_bool "bind cleanup identity" true (site.incumbent == fresh);
  assert_int "bind cleanup demand" 1 fresh.demand;
  assert_int "bind cleanup visits" 1 site.counts.cleanup_visits;
  assert_int "bind adjacency search" 0 site.counts.adjacency_searches

let check_keyed () =
  let site = create_keyed 4 in
  let child = Int_map.find 2 site.children in
  let root = site.output in
  let next_input = Int_map.add 2 7 site.input in
  keyed_begin site next_input;
  keyed_update_data site 2 7;
  keyed_commit site;
  keyed_cleanup site;
  assert_bool "keyed retained child" true (Int_map.find 2 site.children == child);
  assert_int "keyed retained output" 7 (Int_map.find 2 site.output);
  let committed_root = site.output in
  let removed = Int_map.find 2 site.children in
  keyed_begin site (Int_map.remove 2 site.input);
  keyed_remove site 2;
  keyed_rollback site;
  assert_bool "keyed rollback root" true (site.output == committed_root);
  assert_bool "keyed rollback child" true (Int_map.find 2 site.children == removed);
  assert_bool "keyed rollback scope" true removed.scope.valid;
  keyed_begin site (Int_map.remove 2 site.input);
  keyed_remove site 2;
  keyed_commit site;
  keyed_cleanup site;
  assert_bool "keyed removal scope" false removed.scope.valid;
  keyed_begin site (Int_map.add 2 9 site.input);
  keyed_add site 2 9;
  let replacement = Int_map.find 2 site.candidate_children in
  keyed_commit site;
  keyed_cleanup site;
  assert_bool "keyed reentry identity" false (replacement == removed);
  assert_bool "keyed reentry generation" true (replacement.id <> removed.id);
  assert_bool "keyed old root changed before checks" false (root == site.output);
  assert_int "keyed adjacency search" 0 site.counts.adjacency_searches

let check_mixed_rollback () =
  let site = create_keyed 3 in
  let roots = site.input, site.children, site.output in
  let retained = Int_map.find 0 site.children in
  let removed = Int_map.find 1 site.children in
  let next_input =
    site.input |> Int_map.add 0 8 |> Int_map.remove 1 |> Int_map.add 4 9
  in
  keyed_begin site next_input;
  keyed_update_data site 0 8;
  keyed_remove site 1;
  keyed_add site 4 9;
  let tentative = Int_map.find 4 site.candidate_children in
  keyed_rollback site;
  let old_input, old_children, old_output = roots in
  assert_bool "mixed input root" true (site.input == old_input);
  assert_bool "mixed child root" true (site.children == old_children);
  assert_bool "mixed output root" true (site.output == old_output);
  assert_bool "mixed retained identity" true (Int_map.find 0 site.children == retained);
  assert_bool "mixed removed identity" true (Int_map.find 1 site.children == removed);
  assert_bool "mixed tentative invalid" false tentative.scope.valid;
  assert_int "mixed retained data" 0 retained.data;
  assert_int "mixed rollback visits" 3 site.counts.rollback_visits

let check_affected_only () =
  List.iter
    (fun size ->
      let site = create_keyed size in
      reset_counts site.counts;
      let key = size / 2 in
      keyed_begin site site.input;
      keyed_refresh_child site key 1;
      keyed_commit site;
      keyed_cleanup site;
      assert_int "child-only selected" 1 site.counts.selected_children;
      assert_int "child-only input event" 0 site.counts.input_events;
      assert_int "child-only topology insert" 0 site.counts.edge_inserts;
      assert_int "child-only topology remove" 0 site.counts.edge_removals;
      assert_int "child-only cleanup" 1 site.counts.cleanup_visits)
    [ 1_000; 10_000; 100_000 ]

let check_commit_and_candidates () =
  List.iter
    (fun affected ->
      let site = create_keyed affected in
      reset_counts site.counts;
      keyed_begin site site.input;
      for key = 0 to affected - 1 do
        keyed_refresh_child site key 1
      done;
      keyed_commit site;
      assert_int "constant commit steps" 2 site.counts.commit_steps;
      if affected > 0 then (
        keyed_cleanup site;
        assert_int "affected cleanup visits" affected site.counts.cleanup_visits))
    [ 0; 1; 4; 1_000 ];
  let journal = Action_journal.create 0 in
  Action_journal.switch journal 1;
  Action_journal.rollback journal;
  assert_int "journal rollback" 0 journal.current.value;
  List.iter
    (fun ballast ->
      let topology = persistent_switch ballast in
      assert_int "persistent copy size" ballast (Array.length topology))
    [ 1; 1_000; 100_000 ]

let check_static_bypass () =
  List.iter
    (fun depth ->
      let site = create_bind 0 in
      let value = ref 0 in
      for _ = 1 to depth do
        incr value
      done;
      assert_int "static result" depth !value;
      assert_int "static topology commits" 0 site.counts.commit_steps;
      assert_int "static cleanup" 0 site.counts.cleanup_visits;
      assert_int "static scope visits" 0 site.counts.scope_visits)
    [ 1; 10; 100 ]

let run_checks () =
  check_bind ();
  check_keyed ();
  check_mixed_rollback ();
  check_affected_only ();
  check_commit_and_candidates ();
  check_static_bypass ();
  Printf.printf "all correctness and economics checks passed\n%!"

type workload = {
  name : string;
  graph_size : int;
  run_batch : int -> unit;
  check : unit -> unit;
}

let capsule_dynamic () =
  let site = create_bind 0 in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      next := 1 - !next;
      bind_begin site;
      ignore (bind_switch site !next);
      bind_commit site;
      bind_cleanup site
    done
  in
  {
    name = "capsule.raw.dynamic.switch";
    graph_size = 3;
    run_batch;
    check = (fun () -> assert_int "capsule dynamic" !next site.incumbent.value);
  }

let journal_dynamic () =
  let site = Action_journal.create 0 in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      next := 1 - !next;
      Action_journal.switch site !next;
      site.actions.(0) <- Action_journal.Sentinel;
      site.length <- 0
    done
  in
  {
    name = "journal.raw.dynamic.switch";
    graph_size = 3;
    run_batch;
    check = (fun () -> assert_int "journal dynamic" !next site.current.value);
  }

let incremental_dynamic () =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create false in
  let selected =
    Incr.bind (Incr.Var.watch source) ~f:(fun active ->
      Incr.return (if active then 1 else 0))
  in
  let observer = Incr.observe selected in
  Incr.stabilize ();
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      next := 1 - !next;
      Incr.Var.set source (!next <> 0);
      Incr.stabilize ()
    done
  in
  {
    name = "incremental.raw.dynamic.switch";
    graph_size = 3;
    run_batch;
    check =
      (fun () ->
        assert_int "Incremental dynamic" !next
          (Incr.Observer.value_exn observer));
  }

module E = Eta.Effect
module Signal = Eta_signal.Make (Eta_signal.No_observer_error) ()

type eta_error =
  [ Signal.graph_error | Signal.observer_read_error | Signal.stabilize_error ]

let widen (effect : ('a, [< eta_error ]) E.t) : ('a, eta_error) E.t =
  E.map_error (fun error -> (error :> eta_error)) effect

let run_ok runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith (Eta.Cause.pretty (fun _ -> "typed failure") cause)

let eta_reference_dynamic runtime =
  let source = Signal.Var.create false in
  let selected =
    Signal.bind (Signal.Var.watch source) ~f:(fun active ->
      Signal.const (if active then 1 else 0))
  in
  let observer =
    run_ok runtime
      (Signal.Observer.observe selected ~on_update:(fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  let next = ref 0 in
  let step =
    E.bind
      (fun value ->
        E.bind (fun () -> Signal.stabilize) (Signal.Var.set source value))
      (E.sync (fun () ->
         next := 1 - !next;
         !next <> 0))
  in
  let rec loop remaining =
    if remaining = 0 then E.unit
    else E.bind (fun () -> loop (remaining - 1)) step
  in
  let run_batch operations = run_ok runtime (loop operations) in
  {
    name = "eta_reference.dynamic_scope_cleanup";
    graph_size = 3;
    run_batch;
    check =
      (fun () ->
        assert_int "Eta dynamic" !next
          (run_ok runtime (Signal.Observer.read observer)));
  }

let candidate_keyed kind size =
  let site = create_keyed size in
  let key = size / 2 in
  let extra = size in
  let value = ref 0 in
  let present = ref false in
  let run_batch operations =
    for _ = 1 to operations do
      value := 1 - !value;
      (match kind with
       | `Data ->
           let input = Int_map.add key !value site.input in
           keyed_begin site input;
           keyed_update_data site key !value
       | `Membership ->
           present := not !present;
           let input =
             if !present then Int_map.add extra 1 site.input
             else Int_map.remove extra site.input
           in
           keyed_begin site input;
           if !present then keyed_add site extra 1
           else keyed_remove site extra
       | `Child ->
           keyed_begin site site.input;
           keyed_refresh_child site key !value);
      keyed_commit site;
      keyed_cleanup site
    done
  in
  let suffix =
    match kind with `Data -> "data" | `Membership -> "membership" | `Child -> "child"
  in
  {
    name = Printf.sprintf "capsule.raw.keyed.%s.%d" suffix size;
    graph_size = size;
    run_batch;
    check =
      (fun () ->
        match kind with
        | `Membership ->
            assert_bool "candidate membership" !present
              (Int_map.mem extra site.output)
        | `Data | `Child ->
            assert_int "candidate keyed value" !value
              (Int_map.find key site.output));
  }

let core_base_map size =
  List.init size (fun key -> key, 0)
  |> Core.Map.of_alist_exn (module Core.Int)

let incremental_keyed kind size =
  let module Incr = Incremental.Make () in
  let module IM = Incr_map.Make (Incr) in
  let input = Incr.Var.create (core_base_map size) in
  let children = Array.init size (fun _ -> Incr.Var.create 0) in
  let output =
    match kind with
    | `Child ->
        IM.mapi' (Incr.Var.watch input) ~f:(fun ~key ~data ->
          Incr.map2 data (Incr.Var.watch children.(key))
            ~f:(fun _ child -> child))
    | `Data | `Membership ->
        IM.mapi' (Incr.Var.watch input) ~f:(fun ~key:_ ~data -> data)
  in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let key = size / 2 in
  let extra = size in
  let current = ref (Incr.Var.value input) in
  let value = ref 0 in
  let present = ref false in
  let run_batch operations =
    for _ = 1 to operations do
      value := 1 - !value;
      (match kind with
       | `Data ->
           current := Core.Map.set !current ~key ~data:!value;
           Incr.Var.set input !current
       | `Membership ->
           present := not !present;
           current :=
             (if !present then Core.Map.set !current ~key:extra ~data:1
              else Core.Map.remove !current extra);
           Incr.Var.set input !current
       | `Child -> Incr.Var.set children.(key) !value);
      Incr.stabilize ()
    done
  in
  let suffix =
    match kind with `Data -> "data" | `Membership -> "membership" | `Child -> "child"
  in
  {
    name = Printf.sprintf "incremental.raw.keyed.%s.%d" suffix size;
    graph_size = size;
    run_batch;
    check =
      (fun () ->
        let observed = Incr.Observer.value_exn observer in
        match kind with
        | `Membership ->
            assert_bool "Incremental membership" !present
              (Core.Map.mem observed extra)
        | `Data | `Child ->
            assert_int "Incremental keyed value" !value
              (Option.get (Core.Map.find observed key)));
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

let workloads runtime =
  [
    "capsule.raw.dynamic.switch", capsule_dynamic;
    "journal.raw.dynamic.switch", journal_dynamic;
    "incremental.raw.dynamic.switch", incremental_dynamic;
    ( "eta_reference.dynamic_scope_cleanup",
      fun () -> eta_reference_dynamic runtime );
    "capsule.raw.keyed.data.10000", (fun () -> candidate_keyed `Data 10_000);
    "capsule.raw.keyed.data.100000", (fun () -> candidate_keyed `Data 100_000);
    ( "capsule.raw.keyed.membership.10000",
      fun () -> candidate_keyed `Membership 10_000 );
    ( "capsule.raw.keyed.membership.100000",
      fun () -> candidate_keyed `Membership 100_000 );
    "capsule.raw.keyed.child.10000", (fun () -> candidate_keyed `Child 10_000);
    ( "capsule.raw.keyed.child.100000",
      fun () -> candidate_keyed `Child 100_000 );
    ( "incremental.raw.keyed.data.10000",
      fun () -> incremental_keyed `Data 10_000 );
    ( "incremental.raw.keyed.data.100000",
      fun () -> incremental_keyed `Data 100_000 );
    ( "incremental.raw.keyed.membership.10000",
      fun () -> incremental_keyed `Membership 10_000 );
    ( "incremental.raw.keyed.membership.100000",
      fun () -> incremental_keyed `Membership 100_000 );
    ( "incremental.raw.keyed.child.10000",
      fun () -> incremental_keyed `Child 10_000 );
    ( "incremental.raw.keyed.child.100000",
      fun () -> incremental_keyed `Child 100_000 );
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
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch ~clock:(Eio.Stdenv.clock environment) ()
  in
  if check then run_checks ()
  else
    match only with
    | None -> invalid_arg "use --check or --only NAME"
    | Some selected ->
        let workload =
          match List.assoc_opt selected (workloads runtime) with
          | Some make -> make ()
          | None -> invalid_arg "unknown workload"
        in
        Printf.printf
          "name,graph_size,operations,sample,wall_ns,allocated_words\n%!";
        measure ~samples workload
