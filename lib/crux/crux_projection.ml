module Codec = Crux_codec

module Incarnation = struct
  type t = int64

  let equal = Int64.equal
  let compare = Int64.unsigned_compare
  let to_int64 value = value
end

module Kind = struct
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

  let next_id =
    let counter = Atomic.make 0 in
    fun () ->
      let id = Atomic.fetch_and_add counter 1 in
      if id < 0 || id = max_int then
        invalid_arg "Eta_crux.Projection.Kind.define: descriptor identity overflow";
      id

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

  let same left right = left.id = right.id
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
      | Stored stored :: rest ->
          if Kind.same kind stored.kind then
            let stored_key : key = Obj.magic stored.key in
            if kind.key_compare key stored_key = 0 then
              Some
                {
                  key = stored_key;
                  incarnation = stored.incarnation;
                  value = (Obj.magic stored.value : value);
                }
            else loop rest
          else loop rest
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
        if Kind.same kind stored_kind then
          let update : (key, value) update = Obj.magic update in
          if kind.key_compare key (update_key update) = 0 then update :: found
          else found
        else found)
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
  | Change : stored_entry * candidate -> plan
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
      else left.kind.key_compare left.key (Obj.magic right.key)
  | None, _ | _, None ->
      invalid_arg "Eta_crux.Projection: compared an unknown kind"

let compare_stored_candidate catalog (Stored left) (Candidate right) =
  match Catalog.rank catalog left.kind, Catalog.rank catalog right.kind with
  | Some left_rank, Some right_rank ->
      let by_kind = Int.compare left_rank right_rank in
      if by_kind <> 0 then by_kind
      else left.kind.key_compare left.key (Obj.magic right.key)
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
        else if old.occurrence != candidate.occurrence then
          loop (Replace (stored, fresh) :: acc) previous candidates
        else
          let candidate_value = Obj.magic candidate.value in
          if old.kind.cutoff old.value candidate_value then
            loop (Keep stored :: acc) previous candidates
          else
            loop (Change (stored, fresh) :: acc) previous candidates
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
    | Change (Stored old, Candidate fresh) :: rest ->
        let key = Obj.magic fresh.key in
        let value = Obj.magic fresh.value in
        let entry =
          {
            key;
            incarnation = old.incarnation;
            value;
          }
        in
        let stored =
          Stored
            {
              occurrence = fresh.occurrence;
              kind = old.kind;
              key;
              incarnation = old.incarnation;
              value;
            }
        in
        loop (stored :: entries)
          (Packed_update (old.kind, Changed entry) :: updates)
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
