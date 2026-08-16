module Codec = Crux_codec

module Incarnation = struct
  type t = int64

  let equal = Int64.equal
  let compare = Int64.unsigned_compare
  let to_int64 value = value
end

module Kind = struct
  type (_, _) equality = Refl : ('value, 'value) equality

  type ('key, 'value) t = {
    id : int;
    name : string;
    key_compare : 'key -> 'key -> int;
    key_codec : 'key Codec.t;
    value_codec : 'value Codec.t;
    value_equal : 'value -> 'value -> bool;
    cutoff : 'value -> 'value -> bool;
  }

  type packed = Pack : ('key, 'value) t -> packed

  type identity_state =
    | Next of int
    | Exhausted

  let next_id =
    let state = Atomic.make (Next 0) in
    let rec allocate () =
      let current = Atomic.get state in
      match current with
      | Exhausted ->
          invalid_arg
            "Eta_crux.Projection.Kind.define: descriptor identity overflow"
      | Next id ->
          let next =
            if id = max_int then Exhausted else Next (id + 1)
          in
          if Atomic.compare_and_set state current next then
            if id = max_int then
              invalid_arg
                "Eta_crux.Projection.Kind.define: descriptor identity overflow"
            else id
          else allocate ()
    in
    allocate

  let define ~name ~key_compare ~key_codec ~value_codec ~value_equal ~cutoff =
    {
      id = next_id ();
      name;
      key_compare;
      key_codec;
      value_codec;
      value_equal;
      cutoff;
    }

  let equal :
      type left_key left_value right_key right_value.
      (left_key, left_value) t ->
      (right_key, right_value) t ->
      ((left_key, right_key) equality
      * (left_value, right_value) equality)
      option =
   fun left right ->
    if left.id = right.id then
      (* Kind identities are allocated once and never reused. Equal identities
         therefore prove that both descriptors have the same key and value
         types. Keep the representation cast at this proof boundary. *)
      Some (Obj.magic (Refl, Refl))
    else None

  let same left right = Option.is_some (equal left right)

  let cast :
      type left right.
      (left, right) equality -> left -> right =
   fun equal value ->
    match equal with
    | Refl -> value

  let name kind = kind.name
  let key_codec kind = kind.key_codec
  let value_codec kind = kind.value_codec
end

module Catalog = struct
  type t = {
    kinds : Kind.packed list;
    ranks : (int, int) Hashtbl.t;
  }

  let valid_name name =
    let length = String.length name in
    let valid_initial = function
      | 'a' .. 'z' -> true
      | _ -> false
    in
    let valid_rest = function
      | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
      | _ -> false
    in
    length > 0
    && length <= 128
    && valid_initial name.[0]
    &&
    let rec loop index =
      index = length || (valid_rest name.[index] && loop (index + 1))
    in
    loop 1

  let create kinds =
    let ranks = Hashtbl.create (List.length kinds) in
    let names = Hashtbl.create (List.length kinds) in
    List.iteri
      (fun rank ((Kind.Pack kind as packed) : Kind.packed) ->
        if not (valid_name kind.name) then
          invalid_arg
            "Eta_crux.Projection.Catalog.create: invalid projection kind name";
        if Hashtbl.mem ranks kind.id then
          invalid_arg
            "Eta_crux.Projection.Catalog.create: duplicate projection kind";
        if Hashtbl.mem names kind.name then
          invalid_arg
            "Eta_crux.Projection.Catalog.create: duplicate projection kind name";
        Hashtbl.add ranks kind.id rank;
        Hashtbl.add names kind.name packed)
      kinds;
    { kinds; ranks }

  let rank catalog kind = Hashtbl.find_opt catalog.ranks kind.Kind.id

  let[@zero_alloc assume] rank_raw catalog kind =
    try
      (Hashtbl.find [@zero_alloc assume])
        catalog.ranks kind.Kind.id
    with Not_found -> -1
end

type preflight_error =
  | Unknown_kind
  | Identity_collision
  | Projection_capacity_exceeded
  | Incarnation_exhausted

type ('key, 'value) entry = {
  key : 'key;
  incarnation : Incarnation.t;
  value : 'value;
}

type ('key, 'value) update =
  | Attached of ('key, 'value) entry
  | Changed of ('key, 'value) entry
  | Removed of {
      key : 'key;
      incarnation : Incarnation.t;
    }

let cast_update :
    type left_key right_key left_value right_value.
    (left_key, right_key) Kind.equality ->
    (left_value, right_value) Kind.equality ->
    (left_key, left_value) update ->
    (right_key, right_value) update =
 fun key_equal value_equal update ->
  match key_equal with
  | Kind.Refl -> (
      match value_equal with
      | Kind.Refl -> update)

type occurrence = { id : int }

let next_candidate_stamp =
  let next = Atomic.make 0 in
  let rec take () =
    let current = Atomic.get next in
    if current = max_int then
      invalid_arg "Eta_crux.Projection: candidate stamp exhausted"
    else if Atomic.compare_and_set next current (current + 1) then
      current
    else take ()
  in
  take

type candidate =
  | Candidate : {
      stamp : int;
      occurrence : occurrence;
      kind : ('key, 'value) Kind.t;
      key : 'key;
      value : 'value;
    } -> candidate

(* This persistent manifest is keyed by occurrence identity, not by projection
   identity. State.prepare validates and, when needed, canonicalizes by catalog
   rank and key. Candidate stamps detect recomputation without retaining
   candidate values in committed snapshots. *)
type candidates =
  | Candidates_empty
  | Candidates_node of {
      left : candidates;
      candidate : candidate;
      right : candidates;
      height : int;
      size : int;
    }

type stored_entry =
  | Stored : {
      stamp : int;
      rank : int;
      occurrence : occurrence;
      kind : ('key, 'value) Kind.t;
      key : 'key;
      incarnation : Incarnation.t;
      value : 'value;
    } -> stored_entry

type snapshot_tree =
  | Empty
  | Node of {
      left : snapshot_tree;
      entry : stored_entry;
      right : snapshot_tree;
    }

module Snapshot = struct
  type t = {
    tree : snapshot_tree;
    cardinal : int;
  }

  type packed_entry =
    | Pack :
        ('key, 'value) Kind.t * ('key, 'value) entry ->
        packed_entry

  let find_opt (type key value) (kind : (key, value) Kind.t) ~key snapshot =
    let rec loop = function
      | Empty -> None
      | Node { left; entry = Stored stored; right } -> (
          match Kind.equal stored.kind kind with
          | Some (key_equal, value_equal) ->
              let stored_key = Kind.cast key_equal stored.key in
              if kind.key_compare key stored_key = 0 then
                Some
                  {
                    key = stored_key;
                    incarnation = stored.incarnation;
                    value = Kind.cast value_equal stored.value;
                  }
              else (
                match loop left with
                | Some _ as found -> found
                | None -> loop right)
          | None -> (
              match loop left with
              | Some _ as found -> found
              | None -> loop right))
    in
    loop snapshot.tree

  let fold snapshot ~init ~f =
    let rec loop tree acc =
      match tree with
      | Empty -> acc
      | Node { left; entry = Stored stored; right } ->
          let acc = loop left acc in
          let acc =
            f acc
              (Pack
                 ( stored.kind,
                   {
                     key = stored.key;
                     incarnation = stored.incarnation;
                     value = stored.value;
                   } ))
          in
          loop right acc
    in
    loop snapshot.tree init
end

type packed_update =
  | Packed_update :
      ('key, 'value) Kind.t * ('key, 'value) update ->
      packed_update

module Batch = struct
  type t = {
    updates : packed_update list;
    target : Snapshot.t;
  }

  type packed_update =
    | Pack :
        ('key, 'value) Kind.t * ('key, 'value) update ->
        packed_update

  let update_key = function
    | Attached entry | Changed entry -> entry.key
    | Removed { key; _ } -> key

  let find_opt (type key value) (kind : (key, value) Kind.t) ~key batch =
    List.fold_left
      (fun found (Packed_update (stored_kind, update)) ->
        match Kind.equal stored_kind kind with
        | Some (key_equal, value_equal) ->
            let update = cast_update key_equal value_equal update in
            if kind.key_compare key (update_key update) = 0 then update :: found
            else found
        | None -> found)
      [] batch.updates
    |> List.rev

  let rec fold_updates f acc = function
    | [] -> acc
    | Packed_update (kind, update) :: rest ->
        fold_updates f (f acc (Pack (kind, update))) rest

  let fold batch ~init ~f =
    fold_updates f init batch.updates

  let target_snapshot batch = batch.target
end

type delivery =
  | Updates of Batch.t
  | Bootstrap of Snapshot.t

module Commit = struct
  type t = {
    snapshot : Snapshot.t;
    batch : Batch.t;
  }

  let create snapshot batch =
    { snapshot; batch }

  let[@inline always] snapshot commit = commit.snapshot
  let[@inline always] batch commit = commit.batch
end

let next_occurrence =
  let next = Atomic.make 0 in
  let rec take () =
    let id = Atomic.get next in
    if id = max_int then
      invalid_arg "Eta_crux.Projection.publish: occurrence identity overflow";
    if Atomic.compare_and_set next id (id + 1) then { id }
    else take ()
  in
  take

let occurrence = next_occurrence
let candidate ~occurrence kind ~key value =
  Candidate
    {
      stamp = next_candidate_stamp ();
      occurrence;
      kind;
      key;
      value;
    }

let candidates_empty = Candidates_empty

let[@zero_alloc] candidates_height = function
  | Candidates_empty -> 0
  | Candidates_node node -> node.height

let[@zero_alloc] candidates_size = function
  | Candidates_empty -> 0
  | Candidates_node node -> node.size

let[@zero_alloc] candidate_occurrence (Candidate candidate) =
  candidate.occurrence.id

let candidates_node left candidate right =
  Candidates_node
    {
      left;
      candidate;
      right;
      height =
        1 + max (candidates_height left) (candidates_height right);
      size = 1 + candidates_size left + candidates_size right;
    }

let candidates_balance left candidate right =
  let left_height = candidates_height left in
  let right_height = candidates_height right in
  if left_height > right_height + 2 then
    match left with
    | Candidates_empty -> assert false
    | Candidates_node left_node ->
        if
          candidates_height left_node.left
          >= candidates_height left_node.right
        then
          candidates_node left_node.left left_node.candidate
            (candidates_node left_node.right candidate right)
        else (
          match left_node.right with
          | Candidates_empty -> assert false
          | Candidates_node middle ->
              candidates_node
                (candidates_node left_node.left
                   left_node.candidate middle.left)
                middle.candidate
                (candidates_node middle.right candidate right))
  else if right_height > left_height + 2 then
    match right with
    | Candidates_empty -> assert false
    | Candidates_node right_node ->
        if
          candidates_height right_node.right
          >= candidates_height right_node.left
        then
          candidates_node
            (candidates_node left candidate right_node.left)
            right_node.candidate right_node.right
        else (
          match right_node.left with
          | Candidates_empty -> assert false
          | Candidates_node middle ->
              candidates_node
                (candidates_node left candidate middle.left)
                middle.candidate
                (candidates_node middle.right
                   right_node.candidate right_node.right))
  else candidates_node left candidate right

let rec candidates_add candidate = function
  | Candidates_empty ->
      candidates_node Candidates_empty candidate Candidates_empty
  | Candidates_node node as candidates ->
      let compared =
        Int.compare (candidate_occurrence candidate)
          (candidate_occurrence node.candidate)
      in
      if compared = 0 then
        if candidate == node.candidate then candidates
        else candidates_node node.left candidate node.right
      else if compared < 0 then
        let left = candidates_add candidate node.left in
        if left == node.left then candidates
        else candidates_balance left node.candidate node.right
      else
        let right = candidates_add candidate node.right in
        if right == node.right then candidates
        else candidates_balance node.left node.candidate right

let rec candidates_min = function
  | Candidates_empty -> assert false
  | Candidates_node { left = Candidates_empty; candidate; _ } ->
      candidate
  | Candidates_node node -> candidates_min node.left

let rec candidates_remove occurrence = function
  | Candidates_empty -> Candidates_empty
  | Candidates_node node as candidates ->
      let compared =
        Int.compare occurrence
          (candidate_occurrence node.candidate)
      in
      if compared = 0 then
        match node.left, node.right with
        | Candidates_empty, right -> right
        | left, Candidates_empty -> left
        | left, right ->
            let candidate = candidates_min right in
            candidates_balance left candidate
              (candidates_remove
                 (candidate_occurrence candidate)
                 right)
      else if compared < 0 then
        let left = candidates_remove occurrence node.left in
        if left == node.left then candidates
        else candidates_balance left node.candidate node.right
      else
        let right = candidates_remove occurrence node.right in
        if right == node.right then candidates
        else candidates_balance node.left node.candidate right

let rec candidates_mem occurrence = function
  | Candidates_empty -> false
  | Candidates_node node ->
      let compared =
        Int.compare occurrence
          (candidate_occurrence node.candidate)
      in
      if compared = 0 then true
      else if compared < 0 then
        candidates_mem occurrence node.left
      else candidates_mem occurrence node.right

let rec candidates_fold candidates acc ~f =
  match candidates with
  | Candidates_empty -> acc
  | Candidates_node node ->
      let acc = candidates_fold node.left acc ~f in
      let acc = f acc node.candidate in
      candidates_fold node.right acc ~f

let candidates_prepend candidate candidates =
  candidates_add candidate candidates

let candidates_append left right =
  if left == right then left
  else if candidates_size left <= candidates_size right then
    candidates_fold left right
      ~f:(fun candidates candidate ->
        candidates_add candidate candidates)
  else
    candidates_fold right left
      ~f:(fun candidates candidate ->
        candidates_add candidate candidates)

let candidates_equal left right = left == right

let candidates_replace ~previous ~current candidates =
  let candidates =
    candidates_fold previous candidates
      ~f:(fun candidates candidate ->
        let occurrence = candidate_occurrence candidate in
        if candidates_mem occurrence current then candidates
        else candidates_remove occurrence candidates)
  in
  candidates_fold current candidates
    ~f:(fun candidates candidate ->
      candidates_add candidate candidates)

type plan =
  | Keep of stored_entry
  | Change : {
      stamp : int;
      rank : int;
      occurrence : occurrence;
      kind : ('key, 'value) Kind.t;
      key : 'key;
      incarnation : Incarnation.t;
      value : 'value;
    } -> plan
  | Attach of candidate
  | Remove of stored_entry
  | Replace : stored_entry * candidate -> plan

let candidate_rank catalog (Candidate candidate) =
  Catalog.rank catalog candidate.kind

let compare_candidates catalog (Candidate left) (Candidate right) =
  match Catalog.rank catalog left.kind, Catalog.rank catalog right.kind with
  | Some left_rank, Some right_rank ->
      let by_kind = Int.compare left_rank right_rank in
      if by_kind <> 0 then by_kind
      else (
        match Kind.equal right.kind left.kind with
        | Some (key_equal, _value_equal) ->
            left.kind.key_compare left.key
              (Kind.cast key_equal right.key)
        | None ->
            invalid_arg
              "Eta_crux.Projection: catalog rank does not identify one kind")
  | None, _ | _, None ->
      invalid_arg "Eta_crux.Projection: compared an unknown kind"

let compare_stored_candidate catalog (Stored left) (Candidate right) =
  match Catalog.rank catalog left.kind, Catalog.rank catalog right.kind with
  | Some left_rank, Some right_rank ->
      let by_kind = Int.compare left_rank right_rank in
      if by_kind <> 0 then by_kind
      else (
        match Kind.equal right.kind left.kind with
        | Some (key_equal, _value_equal) ->
            left.kind.key_compare left.key
              (Kind.cast key_equal right.key)
        | None ->
            invalid_arg
              "Eta_crux.Projection: catalog rank does not identify one kind")
  | None, _ | _, None ->
      invalid_arg "Eta_crux.Projection: compared an unknown kind"

let collision_free catalog candidates =
  let rec loop = function
    | left :: (right :: _ as rest) ->
        if compare_candidates catalog left right = 0 then false else loop rest
    | [] | [ _ ] -> true
  in
  loop candidates

let plans catalog previous candidates =
  let rec loop acc previous candidates =
    match previous, candidates with
    | [], [] -> List.rev acc
    | [], candidate :: candidates ->
        loop (Attach candidate :: acc) [] candidates
    | stored :: previous, [] ->
        loop (Remove stored :: acc) previous []
    | (Stored old as stored) :: previous,
      (Candidate candidate as fresh) :: candidates ->
        let compared = compare_stored_candidate catalog stored fresh in
        if compared < 0 then
          loop (Remove stored :: acc) previous (fresh :: candidates)
        else if compared > 0 then
          loop (Attach fresh :: acc) (stored :: previous) candidates
        else (
          match Kind.equal candidate.kind old.kind with
          | None ->
              invalid_arg
                "Eta_crux.Projection: equal identities have different kinds"
          | Some (_key_equal, value_equal) ->
              if old.stamp = candidate.stamp then
                loop (Keep stored :: acc) previous candidates
              else if old.occurrence != candidate.occurrence then
                loop (Replace (stored, fresh) :: acc) previous candidates
              else if
                old.kind.cutoff old.value
                  (Kind.cast value_equal candidate.value)
              then loop (Keep stored :: acc) previous candidates
              else
                loop
                  (Change
                     {
                       stamp = candidate.stamp;
                       rank = old.rank;
                       occurrence = candidate.occurrence;
                       kind = candidate.kind;
                       key = candidate.key;
                       incarnation = old.incarnation;
                       value = candidate.value;
                     }
                  :: acc)
                  previous candidates)
  in
  loop [] previous candidates

let update_count plans =
  List.fold_left
    (fun count -> function
      | Keep _ -> count
      | Change _ | Remove _ | Attach _ -> count + 1
      | Replace _ -> count + 2)
    0 plans

let allocate counter =
  if Int64.equal counter 0L then Error Incarnation_exhausted
  else Ok (counter, Int64.add counter 1L)

let materialize catalog plans next_incarnation =
  let rec loop entries updates counter = function
    | [] -> Ok (List.rev entries, List.rev updates, counter)
    | Keep stored :: rest ->
        loop (stored :: entries) updates counter rest
    | Change changed :: rest ->
        let entry =
          {
            key = changed.key;
            incarnation = changed.incarnation;
            value = changed.value;
          }
        in
        let stored =
          Stored
            {
              stamp = changed.stamp;
              rank = changed.rank;
              occurrence = changed.occurrence;
              kind = changed.kind;
              key = changed.key;
              incarnation = changed.incarnation;
              value = changed.value;
            }
        in
        loop (stored :: entries)
          (Packed_update (changed.kind, Changed entry) :: updates)
          counter rest
    | Remove (Stored old) :: rest ->
        loop entries
          (Packed_update
             ( old.kind,
               Removed
                 {
                   key = old.key;
                   incarnation = old.incarnation;
                 } )
          :: updates)
          counter rest
    | Attach (Candidate fresh) :: rest -> (
        match allocate counter with
        | Error _ as error -> error
        | Ok (incarnation, counter) ->
            let entry =
              {
                key = fresh.key;
                incarnation;
                value = fresh.value;
              }
            in
            let stored =
              Stored
                {
                  stamp = fresh.stamp;
                  rank = Option.get (Catalog.rank catalog fresh.kind);
                  occurrence = fresh.occurrence;
                  kind = fresh.kind;
                  key = fresh.key;
                  incarnation;
                  value = fresh.value;
                }
            in
            loop (stored :: entries)
              (Packed_update (fresh.kind, Attached entry) :: updates)
              counter rest)
    | Replace (Stored old, Candidate fresh) :: rest -> (
        match allocate counter with
        | Error _ as error -> error
        | Ok (incarnation, counter) ->
            let entry =
              {
                key = fresh.key;
                incarnation;
                value = fresh.value;
              }
            in
            let stored =
              Stored
                {
                  stamp = fresh.stamp;
                  rank = old.rank;
                  occurrence = fresh.occurrence;
                  kind = fresh.kind;
                  key = fresh.key;
                  incarnation;
                  value = fresh.value;
                }
            in
            loop (stored :: entries)
              (Packed_update (fresh.kind, Attached entry)
              :: Packed_update
                   ( old.kind,
                     Removed
                       {
                         key = old.key;
                         incarnation = old.incarnation;
                       } )
              :: updates)
              counter rest)
  in
  loop [] [] next_incarnation plans

let rec tree_to_list tree tail =
  match tree with
  | Empty -> tail
  | Node { left; entry; right } ->
      tree_to_list left (entry :: tree_to_list right tail)

let tree_of_list entries =
  let entries = Array.of_list entries in
  let rec build start length =
    if length = 0 then Empty
    else
      let left_length = length / 2 in
      let index = start + left_length in
      Node
        {
          left = build start left_length;
          entry = entries.(index);
          right =
            build (index + 1)
              (length - left_length - 1);
        }
  in
  build 0 (Array.length entries)

let[@zero_alloc] candidates_count candidates =
  candidates_size candidates

let[@zero_alloc] rec fill_candidates candidates array index =
  match candidates with
  | Candidates_empty -> index
  | Candidates_node node ->
      let index = fill_candidates node.left array index in
      let candidate = node.candidate in
      Array.unsafe_set array index candidate;
      fill_candidates node.right array (index + 1)

module State = struct
  type prepared = {
    commit : Commit.t;
    next_incarnation : int64;
  }

  type t = {
    catalog : Catalog.t;
    capacity : int;
    mutable snapshot : Snapshot.t option;
    mutable next_incarnation : int64;
    mutable scratch_candidates : candidate array option;
    mutable scratch_ranks : int array;
    mutable scan : int;
    mutable updates : packed_update list;
    mutable update_count : int;
    mutable refresh_next_incarnation : int64;
    mutable refresh_error : preflight_error option;
    mutable empty_prepared : prepared;
  }

  let create ~catalog ~capacity =
    if capacity <= 0 then
      invalid_arg
        "Eta_crux.Root.create: projection_capacity must be positive";
    let snapshot =
      { Snapshot.tree = Empty; cardinal = 0 }
    in
    let batch = { Batch.updates = []; target = snapshot } in
    let empty_prepared =
      {
        commit = Commit.create snapshot batch;
        next_incarnation = 1L;
      }
    in
    {
      catalog;
      capacity;
      snapshot = None;
      next_incarnation = 1L;
      scratch_candidates = None;
      scratch_ranks = [||];
      scan = 0;
      updates = [];
      update_count = 0;
      refresh_next_incarnation = 1L;
      refresh_error = None;
      empty_prepared;
    }

  let[@zero_alloc] candidate_at state index =
    match state.scratch_candidates with
    | Some candidates -> Array.unsafe_get candidates index
    | None -> assert false

  let ensure_scratch state candidates count =
    match state.scratch_candidates with
    | Some current when Array.length current = count -> current
    | Some _ | None ->
        let rec first = function
          | Candidates_empty -> assert false
          | Candidates_node
              { left = Candidates_empty; candidate; _ } ->
              candidate
          | Candidates_node node -> first node.left
        in
        let current = Array.make count (first candidates) in
        state.scratch_candidates <- Some current;
        state.scratch_ranks <- Array.make count 0;
        current

  let[@zero_alloc assume] rank_raw catalog (Candidate candidate) =
    (* The standard-library table and the user-supplied comparator are indirect
       calls, so the checker cannot inspect them. The checked walk itself owns
       no allocation; these two calls are its explicit trusted boundary. *)
    Catalog.rank_raw catalog candidate.kind

  let[@zero_alloc] compare_at state left_index right_index =
    let left_rank = Array.unsafe_get state.scratch_ranks left_index in
    let right_rank = Array.unsafe_get state.scratch_ranks right_index in
    let by_kind = Int.compare left_rank right_rank in
    if by_kind <> 0 then by_kind
    else
      match
        candidate_at state left_index,
        candidate_at state right_index
      with
      | Candidate left, Candidate right ->
          (* Equal catalog ranks identify one kind, so the existential key types
             are equal at this boundary. *)
          (left.kind.key_compare [@zero_alloc assume])
            left.key (Obj.magic right.key)

  let[@zero_alloc] rec validate_order_loop state count index sorted =
    if index = count then if sorted then 0 else 1
    else
      let compared = compare_at state (index - 1) index in
      if compared = 0 then 2
      else
        validate_order_loop state count (index + 1)
          (sorted && compared < 0)

  let[@zero_alloc] validate_order state count =
    validate_order_loop state count 1 true

  let sort_scratch state candidates =
    Array.stable_sort
      (compare_candidates state.catalog)
      candidates;
    Array.iteri
      (fun index candidate ->
        Array.unsafe_set state.scratch_ranks index
          (rank_raw state.catalog candidate))
      candidates

  let[@zero_alloc] compare_stored_at state (Stored stored) index =
    let rank = Array.unsafe_get state.scratch_ranks index in
    let by_kind = Int.compare stored.rank rank in
    if by_kind <> 0 then by_kind
    else
      match candidate_at state index with
      | Candidate candidate ->
          (* Equal catalog ranks identify one kind, so the existential key types
             are equal at this boundary. *)
          (stored.kind.key_compare [@zero_alloc assume])
            stored.key (Obj.magic candidate.key)

  let[@zero_alloc] rec same_identities state = function
    | Empty -> true
    | Node { left; entry; right } ->
        same_identities state left
        &&
        let index = state.scan in
        state.scan <- index + 1;
        compare_stored_at state entry index = 0
        && same_identities state right

  let fresh_incarnation state =
    let current = state.refresh_next_incarnation in
    if Int64.equal current 0L then (
      state.refresh_error <- Some Incarnation_exhausted;
      None)
    else (
      state.refresh_next_incarnation <- Int64.add current 1L;
      Some current)

  let refresh_entry state ((Stored stored) as previous) candidate =
    match candidate with
    | Candidate fresh -> (
        match Kind.equal fresh.kind stored.kind with
        | None ->
            invalid_arg
              "Eta_crux.Projection: equal identities have different kinds"
        | Some (_key_equal, value_equal) ->
            if stored.stamp = fresh.stamp then previous
            else if stored.occurrence != fresh.occurrence then
              match fresh_incarnation state with
              | None -> previous
              | Some incarnation ->
                  let entry =
                    {
                      key = fresh.key;
                      incarnation;
                      value = fresh.value;
                    }
                  in
                  state.updates <-
                    Packed_update (fresh.kind, Attached entry)
                    :: Packed_update
                         ( stored.kind,
                           Removed
                             {
                               key = stored.key;
                               incarnation = stored.incarnation;
                             } )
                    :: state.updates;
                  state.update_count <- state.update_count + 2;
                  Stored
                    {
                      stamp = fresh.stamp;
                      rank = stored.rank;
                      occurrence = fresh.occurrence;
                      kind = fresh.kind;
                      key = fresh.key;
                      incarnation;
                      value = fresh.value;
                    }
            else if
              stored.kind.cutoff stored.value
                (Kind.cast value_equal fresh.value)
            then previous
            else
              let entry =
                {
                  key = fresh.key;
                  incarnation = stored.incarnation;
                  value = fresh.value;
                }
              in
              state.updates <-
                Packed_update (fresh.kind, Changed entry)
                :: state.updates;
              state.update_count <- state.update_count + 1;
              Stored
                {
                  stamp = fresh.stamp;
                  rank = stored.rank;
                  occurrence = fresh.occurrence;
                  kind = fresh.kind;
                  key = fresh.key;
                  incarnation = stored.incarnation;
                  value = fresh.value;
                })

  let rec refresh_tree state = function
    | Empty -> Empty
    | (Node node as tree) ->
        let left = refresh_tree state node.left in
        let index = state.scan in
        state.scan <- index + 1;
        let entry =
          refresh_entry state node.entry
            (candidate_at state index)
        in
        let right = refresh_tree state node.right in
        if
          left == node.left && entry == node.entry
          && right == node.right
        then tree
        else Node { left; entry; right }

  let prepare_fast state previous count =
    state.scan <- 0;
    state.updates <- [];
    state.update_count <- 0;
    state.refresh_next_incarnation <- state.next_incarnation;
    state.refresh_error <- None;
    let tree = refresh_tree state previous.Snapshot.tree in
    match state.refresh_error with
    | Some error -> Error error
    | None when state.update_count > state.capacity ->
        Error Projection_capacity_exceeded
    | None ->
        let snapshot = { Snapshot.tree; cardinal = count } in
        let updates = List.rev state.updates in
        let batch = { Batch.updates; target = snapshot } in
        Ok
          {
            commit = Commit.create snapshot batch;
            next_incarnation = state.refresh_next_incarnation;
          }

  let candidates_to_list state count =
    let rec loop index acc =
      if index < 0 then acc
      else loop (index - 1) (candidate_at state index :: acc)
    in
    loop (count - 1) []

  let prepare_fallback state count =
    let candidates = candidates_to_list state count in
    let previous =
      match state.snapshot with
      | None -> []
      | Some snapshot -> tree_to_list snapshot.tree []
    in
    let plans = plans state.catalog previous candidates in
    if update_count plans > state.capacity then
      Error Projection_capacity_exceeded
    else
      match
        materialize state.catalog plans state.next_incarnation
      with
      | Error _ as error -> error
      | Ok (entries, updates, next_incarnation) ->
          let snapshot =
            {
              Snapshot.tree = tree_of_list entries;
              cardinal = List.length entries;
            }
          in
          let batch = { Batch.updates; target = snapshot } in
          Ok
            {
              commit = Commit.create snapshot batch;
              next_incarnation;
            }

  let[@inline always] refresh_empty_prepared state =
    let previous = state.empty_prepared in
    let prepared =
      {
        commit =
          Commit.create previous.commit.snapshot
            previous.commit.batch;
        next_incarnation = state.next_incarnation;
      }
    in
    state.empty_prepared <- prepared;
    prepared

  let prepare state candidates =
    let count = candidates_count candidates in
    if count > state.capacity then
      Error Projection_capacity_exceeded
    else if count = 0 then
      let () =
        state.scratch_candidates <- None;
        state.scratch_ranks <- [||]
      in
      match state.snapshot with
      | Some previous when previous.cardinal <> 0 ->
          prepare_fallback state count
      | None | Some _ ->
          Ok (refresh_empty_prepared state)
    else
      let scratch = ensure_scratch state candidates count in
      ignore (fill_candidates candidates scratch 0);
      let known = ref true in
      for index = 0 to count - 1 do
        let rank =
          rank_raw state.catalog (Array.unsafe_get scratch index)
        in
        Array.unsafe_set state.scratch_ranks index rank;
        if rank < 0 then known := false
      done;
      if not !known then Error Unknown_kind
      else
        let ordered =
          match validate_order state count with
          | 2 -> 2
          | 0 -> 0
          | 1 ->
              sort_scratch state scratch;
              validate_order state count
          | _ -> assert false
        in
        match ordered with
        | 2 -> Error Identity_collision
        | 1 -> assert false
        | 0 -> (
            match state.snapshot with
            | Some previous when previous.cardinal = count ->
                state.scan <- 0;
                if same_identities state previous.tree then
                  prepare_fast state previous count
                else prepare_fallback state count
            | None | Some _ -> prepare_fallback state count)
        | _ -> assert false

  let[@inline always] commit prepared = prepared.commit

  let[@inline always] install state prepared =
    state.snapshot <- Some prepared.commit.snapshot;
    state.next_incarnation <- prepared.next_incarnation

  let set_next_incarnation_for_test (state : t) next =
    state.next_incarnation <- next
end

let snapshot_of_delivery = function
  | Updates batch -> Batch.target_snapshot batch
  | Bootstrap snapshot -> snapshot
