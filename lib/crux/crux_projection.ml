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

type occurrence = unit ref

type candidate =
  | Candidate : {
      occurrence : occurrence;
      kind : ('key, 'value) Kind.t;
      key : 'key;
      value : 'value;
    } -> candidate

type stored_entry =
  | Stored : {
      occurrence : occurrence;
      kind : ('key, 'value) Kind.t;
      key : 'key;
      incarnation : Incarnation.t;
      value : 'value;
    } -> stored_entry

module Snapshot = struct
  type t = stored_entry list

  type packed_entry =
    | Pack :
        ('key, 'value) Kind.t * ('key, 'value) entry ->
        packed_entry

  let find_opt (type key value) (kind : (key, value) Kind.t) ~key snapshot =
    let rec loop = function
      | [] -> None
      | Stored stored :: rest -> (
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
              else loop rest
          | None -> loop rest)
    in
    loop snapshot

  let fold snapshot ~init ~f =
    List.fold_left
      (fun acc (Stored stored) ->
        f acc
          (Pack
             ( stored.kind,
               {
                 key = stored.key;
                 incarnation = stored.incarnation;
                 value = stored.value;
               } )))
      init snapshot
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

  let fold batch ~init ~f =
    List.fold_left
      (fun acc (Packed_update (kind, update)) ->
        f acc (Pack (kind, update)))
      init batch.updates

  let target_snapshot batch = batch.target
end

module Commit = struct
  type t = {
    snapshot : Snapshot.t;
    batch : Batch.t;
  }

  let snapshot commit = commit.snapshot
  let batch commit = commit.batch
end

type delivery =
  | Updates of Batch.t
  | Bootstrap of Snapshot.t

let occurrence () = ref ()
let candidate ~occurrence kind ~key value = Candidate { occurrence; kind; key; value }

type plan =
  | Keep of stored_entry
  | Change : {
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
              if old.occurrence != candidate.occurrence then
                loop (Replace (stored, fresh) :: acc) previous candidates
              else if
                old.kind.cutoff old.value
                  (Kind.cast value_equal candidate.value)
              then loop (Keep stored :: acc) previous candidates
              else
                loop
                  (Change
                     {
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

let materialize plans next_incarnation =
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

module State = struct
  type t = {
    catalog : Catalog.t;
    capacity : int;
    mutable snapshot : Snapshot.t option;
    mutable next_incarnation : int64;
  }

  type prepared = {
    commit : Commit.t;
    next_incarnation : int64;
  }

  let create ~catalog ~capacity =
    if capacity <= 0 then
      invalid_arg
        "Eta_crux.Root.create: projection_capacity must be positive";
    {
      catalog;
      capacity;
      snapshot = None;
      next_incarnation = 1L;
    }

  let prepare state candidates =
    if
      List.exists
        (fun candidate -> Option.is_none (candidate_rank state.catalog candidate))
        candidates
    then Error Unknown_kind
    else if List.length candidates > state.capacity then
      Error Projection_capacity_exceeded
    else
      let candidates =
        List.stable_sort (compare_candidates state.catalog) candidates
      in
      if not (collision_free state.catalog candidates) then
        Error Identity_collision
      else
        let previous = Option.value ~default:[] state.snapshot in
        let plans = plans state.catalog previous candidates in
        if update_count plans > state.capacity then
          Error Projection_capacity_exceeded
        else
          match materialize plans state.next_incarnation with
          | Error _ as error -> error
          | Ok (snapshot, updates, next_incarnation) ->
              let batch = { Batch.updates; target = snapshot } in
              Ok
                {
                  commit = { Commit.snapshot; batch };
                  next_incarnation;
                }

  let commit prepared = prepared.commit

  let install state prepared =
    state.snapshot <- Some prepared.commit.snapshot;
    state.next_incarnation <- prepared.next_incarnation

  let set_next_incarnation_for_test (state : t) next =
    state.next_incarnation <- next
end

let snapshot_of_delivery = function
  | Updates batch -> Batch.target_snapshot batch
  | Bootstrap snapshot -> snapshot
