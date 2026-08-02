module Key = struct
  type t = {
    rank : int;
    tag : int;
  }

  let compare left right = Int.compare left.rank right.rank
end

module Subject = Eta_signal_map.Map.Make (Key)

type key = Key.t = {
  rank : int;
  tag : int;
}

type data = {
  value : int;
  tag : int;
  mutable marker : int;
}

module Oracle = Stdlib.Map.Make (Int)

type oracle = (key * data) Oracle.t

type edit =
  | Set of int * int
  | Remove of int
  | Update of int * int option

let key rank tag = { rank; tag }
let data value tag = { value; tag; marker = value }

let unique ranks = List.sort_uniq Int.compare ranks

let string_of_int_list values =
  values |> List.map string_of_int |> String.concat ";" |> Printf.sprintf "[%s]"

let string_of_edit = function
  | Set (rank, value) -> Printf.sprintf "set(%d,%d)" rank value
  | Remove rank -> Printf.sprintf "remove(%d)" rank
  | Update (rank, value) ->
      Printf.sprintf "update(%d,%s)" rank
        (match value with None -> "none" | Some value -> string_of_int value)

let string_of_edits edits =
  edits |> List.map string_of_edit |> String.concat ";" |> Printf.sprintf "[%s]"

let rank_lists =
  QCheck.make ~print:string_of_int_list
    QCheck.Gen.(list_size (int_range 0 128) (int_range (-128) 128))

let nonempty_ranks =
  QCheck.make ~print:string_of_int_list
    QCheck.Gen.(list_size (int_range 1 128) (int_range (-128) 128))

let edit_gen =
  let open QCheck.Gen in
  oneof_weighted
    [
      (3, map2 (fun rank value -> Set (rank, value)) (int_range (-64) 64) (int_range (-256) 256));
      (1, map (fun rank -> Remove rank) (int_range (-64) 64));
      (2, map3 (fun rank keep value -> Update (rank, if keep then Some value else None))
            (int_range (-64) 64) bool (int_range (-256) 256));
    ]

let traces =
  QCheck.make ~print:string_of_edits
    QCheck.Gen.(list_size (int_range 1 256) edit_gen)

let fail name generated format =
  Printf.ksprintf
    (fun detail ->
      QCheck.Test.fail_reportf
        "property=%s seed=[0xE22;0x4D4150;n] class=%s counterexample=%s\n%s"
        name name generated detail)
    format

let subject_of_unique_ranks ranks =
  unique ranks
  |> List.fold_left
       (fun map rank -> Subject.set (key rank (rank + 10_000)) (data rank rank) map)
       Subject.empty

let oracle_set supplied_key supplied_data oracle =
  match Oracle.find_opt supplied_key.rank oracle with
  | None -> Oracle.add supplied_key.rank (supplied_key, supplied_data) oracle
  | Some (stored_key, _) ->
      Oracle.add supplied_key.rank (stored_key, supplied_data) oracle

let apply_trace edits =
  List.fold_left
    (fun (subject, oracle, index) edit ->
      match edit with
      | Set (rank, value) ->
          let supplied_key = key rank index in
          let supplied_data = data value index in
          ( Subject.set supplied_key supplied_data subject,
            oracle_set supplied_key supplied_data oracle,
            index + 1 )
      | Remove rank ->
          ( Subject.remove (key rank index) subject,
            Oracle.remove rank oracle,
            index + 1 )
      | Update (rank, value) ->
          let supplied_key = key rank index in
          let supplied_data = Option.map (fun value -> data value index) value in
          let subject = Subject.update supplied_key (fun _ -> supplied_data) subject in
          let oracle =
            match supplied_data with
            | None -> Oracle.remove rank oracle
            | Some supplied_data -> oracle_set supplied_key supplied_data oracle
          in
          (subject, oracle, index + 1))
    (Subject.empty, Oracle.empty, 0) edits

let oracle_to_list oracle = Oracle.bindings oracle |> List.map snd

let same_binding (left_key, left_data) (right_key, right_data) =
  left_key.rank = right_key.rank
  && left_key == right_key
  && left_data == right_data

let same_bindings subject oracle =
  let actual = Subject.to_list subject in
  let expected = oracle_to_list oracle in
  List.length actual = List.length expected
  && List.for_all2 same_binding actual expected

let diff left right =
  Subject.fold_symmetric_diff left right ~init:[]
    ~f:(fun events key change -> (key, change) :: events)
  |> List.rev

let apply_forward map events =
  List.fold_left
    (fun map (key, change) ->
      match change with
      | Eta_signal_map.Map.Left _ -> Subject.remove key map
      | Right value | Changed (_, value) -> Subject.set key value map)
    map events

let apply_reverse map events =
  List.fold_right
    (fun (key, change) map ->
      match change with
      | Eta_signal_map.Map.Left value | Changed (value, _) ->
          Subject.set key value map
      | Right _ -> Subject.remove key map)
    events map

let extensional_equal left right =
  Subject.equal
    (fun left right -> left.value = right.value && left.tag = right.tag)
    left right

let property name count arbitrary f =
  QCheck.Test.make ~name ~count arbitrary (fun value -> f value; true)

(* smmap-eg8v, smmap-or8f *)
let map_empty_is_empty =
  property "map_empty_is_empty" 2_000 QCheck.int (fun probe ->
      if
        not
          (Subject.is_empty Subject.empty
          && Subject.cardinal Subject.empty = 0
          && not (Subject.mem (key probe 0) Subject.empty)
          && Subject.find_opt (key probe 1) Subject.empty = None
          && Subject.to_list Subject.empty = [])
      then fail "map_empty_is_empty" (string_of_int probe) "empty observation mismatch")

(* smmap-4sla *)
let map_singleton_contains_binding =
  property "map_singleton_contains_binding" 2_000 QCheck.(pair int int)
    (fun (rank, value) ->
      let supplied_key = key rank 1 in
      let supplied_data = data value 2 in
      let map = Subject.singleton supplied_key supplied_data in
      match Subject.to_list map with
      | [ (stored_key, stored_data) ]
        when stored_key == supplied_key
             && stored_data == supplied_data
             && Subject.find_opt (key rank 3) map = Some supplied_data ->
          ()
      | _ ->
          fail "map_singleton_contains_binding"
            (Printf.sprintf "%d,%d" rank value)
            "singleton observation mismatch")

(* smmap-dq75 *)
let map_of_list_matches_unique_bindings =
  property "map_of_list_matches_unique_bindings" 2_000 rank_lists (fun ranks ->
      let bindings =
        unique ranks |> List.mapi (fun tag rank -> (key rank tag, data rank tag))
      in
      match Subject.of_list (List.rev bindings) with
      | Error _ ->
          fail "map_of_list_matches_unique_bindings" (string_of_int_list ranks)
            "unique bindings were rejected"
      | Ok map ->
          let expected = List.sort (fun (a, _) (b, _) -> Int.compare a.rank b.rank) bindings in
          if
            List.map (fun (key, data) -> (key.rank, data.value))
              (Subject.to_list map)
            <> List.map (fun (key, data) -> (key.rank, data.value)) expected
          then
            fail "map_of_list_matches_unique_bindings" (string_of_int_list ranks)
              "ordered bindings differ")

(* smmap-cffd, smmap-ikdi *)
let map_of_list_rejects_first_duplicate =
  property "map_of_list_rejects_first_duplicate" 2_000 QCheck.(triple int int int)
    (fun (rank, first_tag, duplicate_tag) ->
      let first = key rank first_tag in
      let duplicate = key rank duplicate_tag in
      let later = key (rank + 1) (duplicate_tag + 1) in
      match
        Subject.of_list
          [ (first, data 1 1); (duplicate, data 2 2); (later, data 3 3); (later, data 4 4) ]
      with
      | Error (`Duplicate_key found) when found == duplicate -> ()
      | _ ->
          fail "map_of_list_rejects_first_duplicate"
            (Printf.sprintf "%d,%d,%d" rank first_tag duplicate_tag)
            "wrong duplicate occurrence")

(* smmap-zdxg *)
let map_keys_are_unique_by_compare =
  property "map_keys_are_unique_by_compare" 2_000 rank_lists (fun ranks ->
      let map =
        List.mapi (fun tag rank -> (rank, tag)) ranks
        |> List.fold_left
             (fun map (rank, tag) -> Subject.set (key rank tag) (data tag tag) map)
             Subject.empty
      in
      if Subject.cardinal map <> List.length (unique ranks) then
        fail "map_keys_are_unique_by_compare" (string_of_int_list ranks)
          "cardinal=%d unique=%d" (Subject.cardinal map)
          (List.length (unique ranks)))

(* smmap-or8f, smmap-bxwh, smmap-8a76, smmap-z7kg *)
let map_lookup_matches_edit_trace =
  property "map_lookup_matches_edit_trace" 2_000 traces (fun edits ->
      let edits =
        [
          Set (0, 1);
          Update (0, Some 2);
          Update (0, None);
          Update (1, None);
          Update (1, Some 3);
          Remove 1;
        ]
        @ edits
      in
      let subject = ref Subject.empty in
      let oracle = ref Oracle.empty in
      List.iteri
        (fun index edit ->
          (match edit with
          | Set (rank, value) ->
              let supplied_key = key rank index in
              let supplied_data = data value index in
              subject := Subject.set supplied_key supplied_data !subject;
              oracle := oracle_set supplied_key supplied_data !oracle
          | Remove rank ->
              subject := Subject.remove (key rank index) !subject;
              oracle := Oracle.remove rank !oracle
          | Update (rank, value) ->
              let supplied_key = key rank index in
              let supplied_data = Option.map (fun value -> data value index) value in
              subject :=
                Subject.update supplied_key (fun _ -> supplied_data) !subject;
              oracle :=
                (match supplied_data with
                | None -> Oracle.remove rank !oracle
                | Some supplied_data ->
                    oracle_set supplied_key supplied_data !oracle));
          if not (same_bindings !subject !oracle) then
            fail "map_lookup_matches_edit_trace" (string_of_edits edits)
              "state mismatch after step %d" index)
        edits)

(* smmap-2sy9 *)
let map_edits_are_persistent =
  property "map_edits_are_persistent" 2_000 traces (fun edits ->
      let split = max 1 (List.length edits / 2) in
      let prefix, suffix =
        let rec take n acc rest =
          if n = 0 then (List.rev acc, rest)
          else match rest with [] -> (List.rev acc, []) | x :: xs -> take (n - 1) (x :: acc) xs
        in
        take split [] edits
      in
      let saved, saved_oracle, _ = apply_trace prefix in
      let saved_bindings = Subject.to_list saved in
      let _current, _oracle, _ = apply_trace (prefix @ suffix) in
      if Subject.to_list saved <> saved_bindings || not (same_bindings saved saved_oracle) then
        fail "map_edits_are_persistent" (string_of_edits edits)
          "saved snapshot changed")

(* smmap-nn25 *)
let map_set_retains_key_representative =
  property "map_set_retains_key_representative" 2_000 QCheck.(pair int int)
    (fun (rank, value) ->
      let stored = key rank 1 in
      let supplied = key rank 2 in
      let map = Subject.singleton stored (data value 1) in
      let changed = Subject.set supplied (data (value + 1) 2) map in
      match Subject.to_list changed with
      | [ (found, _) ] when found == stored -> ()
      | _ ->
          fail "map_set_retains_key_representative"
            (Printf.sprintf "%d,%d" rank value)
            "stored representative changed")

(* smmap-e4r1 *)
let map_reinsert_uses_new_key_representative =
  property "map_reinsert_uses_new_key_representative" 2_000 QCheck.int (fun rank ->
      let old_key = key rank 1 in
      let new_key = key rank 2 in
      let map = Subject.singleton old_key (data 1 1) in
      let map = Subject.remove old_key map |> Subject.set new_key (data 2 2) in
      match Subject.to_list map with
      | [ (found, _) ] when found == new_key -> ()
      | _ ->
          fail "map_reinsert_uses_new_key_representative" (string_of_int rank)
            "reinserted representative was not used")

(* smmap-hht7 *)
let map_physical_noop_preserves_root =
  property "map_physical_noop_preserves_root" 2_000 nonempty_ranks (fun ranks ->
      let map = subject_of_unique_ranks ranks in
      let stored_key, stored_data = List.hd (Subject.to_list map) in
      if
        not
          (Subject.set (key stored_key.rank 999) stored_data map == map
          && Subject.remove (key 1_000_000 0) map == map
          && Subject.update stored_key (fun current -> current) map == map
          && Subject.update (key 1_000_000 0) (fun _ -> None) map == map)
      then
        fail "map_physical_noop_preserves_root" (string_of_int_list ranks)
          "a physical no-op changed the root")

(* smmap-qm48, smmap-b81w *)
let map_ordered_observations_match_oracle =
  property "map_ordered_observations_match_oracle" 2_000 rank_lists (fun ranks ->
      let map = subject_of_unique_ranks ranks in
      let list_ranks = Subject.to_list map |> List.map (fun (key, _) -> key.rank) in
      let fold_ranks =
        Subject.fold (fun key _ acc -> key.rank :: acc) map [] |> List.rev
      in
      let expected = unique ranks in
      if list_ranks <> expected || fold_ranks <> expected then
        fail "map_ordered_observations_match_oracle" (string_of_int_list ranks)
          "ordered observations differ")

(* smmap-i14t *)
let map_map_matches_oracle =
  property "map_map_matches_oracle" 2_000 rank_lists (fun ranks ->
      let map = subject_of_unique_ranks ranks in
      let mapped = Subject.map (fun data -> data.value + 7) map in
      let actual = Subject.to_list mapped |> List.map (fun (key, value) -> (key.rank, value)) in
      let expected = unique ranks |> List.map (fun rank -> (rank, rank + 7)) in
      if actual <> expected then
        fail "map_map_matches_oracle" (string_of_int_list ranks)
          "pointwise map differs")

(* smmap-g2tz *)
let map_filter_mapi_matches_oracle =
  property "map_filter_mapi_matches_oracle" 2_000 rank_lists (fun ranks ->
      let map = subject_of_unique_ranks ranks in
      let filtered =
        Subject.filter_mapi
          (fun key data -> if key.rank mod 2 = 0 then Some (data.value + 1) else None)
          map
      in
      let actual = Subject.to_list filtered |> List.map (fun (key, value) -> (key.rank, value)) in
      let expected =
        unique ranks
        |> List.filter_map (fun rank -> if rank mod 2 = 0 then Some (rank, rank + 1) else None)
      in
      if actual <> expected then
        fail "map_filter_mapi_matches_oracle" (string_of_int_list ranks)
          "filter_mapi differs")

(* smmap-tz92 *)
let map_equal_is_extensional =
  property "map_equal_is_extensional" 2_000 QCheck.(pair rank_lists bool)
    (fun (ranks, make_mismatch) ->
      let ranks = unique ranks in
      let left = subject_of_unique_ranks ranks in
      let right =
        ranks
        |> List.fold_left
             (fun map rank -> Subject.set (key rank (rank + 20_000)) (data rank (rank + 1)) map)
             Subject.empty
      in
      let right =
        if make_mismatch then
          match ranks with
          | [] -> Subject.singleton (key 0 0) (data 1 1)
          | rank :: _ -> Subject.set (key rank 0) (data (rank + 1) 0) right
        else right
      in
      let actual = Subject.equal (fun a b -> a.value = b.value) left right in
      if actual = make_mismatch then
        fail "map_equal_is_extensional" (string_of_int_list ranks)
          "expected equal=%b actual=%b" (not make_mismatch) actual)

(* smmap-aouh *)
let map_equal_checks_all_aligned_data =
  property "map_equal_checks_all_aligned_data" 2_000 rank_lists (fun ranks ->
      let map = subject_of_unique_ranks ranks in
      let calls = ref 0 in
      if not (Subject.equal (fun _ _ -> incr calls; true) map map) then
        fail "map_equal_checks_all_aligned_data" (string_of_int_list ranks)
          "same map was unequal";
      if !calls <> Subject.cardinal map then
        fail "map_equal_checks_all_aligned_data" (string_of_int_list ranks)
          "calls=%d cardinal=%d" !calls (Subject.cardinal map))

(* smmap-ge5r *)
let map_equal_stops_after_rejection =
  property "map_equal_stops_after_rejection" 2_000 QCheck.int (fun rank ->
      let map = subject_of_unique_ranks [ rank; rank + 1; rank + 2 ] in
      let rejected = ref false in
      let result =
        Subject.equal
          (fun data _ ->
            if !rejected then
              fail "map_equal_stops_after_rejection" (string_of_int rank)
                "callback occurred after rejection";
            if data.value = rank + 1 then (rejected := true; false) else true)
          map map
      in
      if result || not !rejected then
        fail "map_equal_stops_after_rejection" (string_of_int rank)
          "rejection was not observed")

(* smdiff-zuwx *)
let map_diff_events_are_ordered_unique =
  property "map_diff_events_are_ordered_unique" 2_000 QCheck.(pair traces traces)
    (fun (left_edits, right_edits) ->
      let left, _, _ = apply_trace left_edits in
      let right, _, _ = apply_trace right_edits in
      let keys = diff left right |> List.map (fun (key, _) -> key.rank) in
      if keys <> List.sort_uniq Int.compare keys then
        fail "map_diff_events_are_ordered_unique"
          (string_of_edits left_edits ^ " / " ^ string_of_edits right_edits)
          "diff keys are not ordered and unique")

(* smdiff-ij95, smdiff-uoix, smdiff-mwo3 *)
let map_diff_reports_physical_changes_only =
  property "map_diff_reports_physical_changes_only" 2_000 QCheck.int (fun value ->
      let shared = data value 1 in
      let mutated_shared = data value 2 in
      let distinct_left = data value 3 in
      let distinct_equal = data value 4 in
      let distinct_right = data (value + 1) 5 in
      let left =
        Subject.empty
        |> Subject.set (key 0 0) shared
        |> Subject.set (key 1 1) mutated_shared
        |> Subject.set (key 2 2) distinct_left
        |> Subject.set (key 3 3) distinct_left
      in
      let right =
        Subject.empty
        |> Subject.set (key 0 10) shared
        |> Subject.set (key 1 11) mutated_shared
        |> Subject.set (key 2 12) distinct_equal
        |> Subject.set (key 3 13) distinct_right
      in
      mutated_shared.marker <- mutated_shared.marker + 1;
      let keys = diff left right |> List.map (fun (key, _) -> key.rank) in
      if keys <> [ 2; 3 ] then
        fail "map_diff_reports_physical_changes_only" (string_of_int value)
          "changed keys=%s" (string_of_int_list keys))

(* smdiff-yhgb *)
let map_diff_uses_map_representatives =
  property "map_diff_uses_map_representatives" 2_000 QCheck.int (fun rank ->
      let left_key = key rank 1 in
      let right_key = key rank 2 in
      let right_only_key = key (rank + 1) 3 in
      let left = Subject.singleton left_key (data 1 1) in
      let right =
        Subject.empty
        |> Subject.set right_key (data 2 2)
        |> Subject.set right_only_key (data 3 3)
      in
      match diff left right with
      | [ (changed_key, Changed _); (added_key, Right _) ]
        when changed_key == left_key && added_key == right_only_key ->
          ()
      | _ ->
          fail "map_diff_uses_map_representatives" (string_of_int rank)
            "event representative mismatch")

(* smdiff-5d9x *)
let map_diff_reconstructs_forward =
  property "map_diff_reconstructs_forward" 2_000 QCheck.(pair traces traces)
    (fun (left_edits, right_edits) ->
      let left, _, _ = apply_trace left_edits in
      let right, _, _ = apply_trace right_edits in
      let rebuilt = apply_forward left (diff left right) in
      if not (extensional_equal rebuilt right) then
        fail "map_diff_reconstructs_forward"
          (string_of_edits left_edits ^ " / " ^ string_of_edits right_edits)
          "forward reconstruction differs")

(* smdiff-4nzq *)
let map_diff_reconstructs_reverse =
  property "map_diff_reconstructs_reverse" 2_000 QCheck.(pair traces traces)
    (fun (left_edits, right_edits) ->
      let left, _, _ = apply_trace left_edits in
      let right, _, _ = apply_trace right_edits in
      let rebuilt = apply_reverse right (diff left right) in
      if not (extensional_equal rebuilt left) then
        fail "map_diff_reconstructs_reverse"
          (string_of_edits left_edits ^ " / " ^ string_of_edits right_edits)
          "reverse reconstruction differs")

(* smdiff-fjnq, smdiff-g1jq *)
let map_diff_handles_independent_maps =
  property "map_diff_handles_independent_maps" 2_000 QCheck.(pair traces traces)
    (fun (left_edits, right_edits) ->
      let left, left_oracle, _ = apply_trace left_edits in
      let right, right_oracle, _ = apply_trace right_edits in
      let expected_keys =
        Oracle.merge
          (fun _ left right ->
            match (left, right) with
            | None, None -> None
            | Some _, None | None, Some _ -> Some ()
            | Some (_, left), Some (_, right) ->
                if left == right then None else Some ())
          left_oracle right_oracle
        |> Oracle.bindings |> List.map fst
      in
      let actual_keys = diff left right |> List.map (fun (key, _) -> key.rank) in
      if actual_keys <> expected_keys then
        fail "map_diff_handles_independent_maps"
          (string_of_edits left_edits ^ " / " ^ string_of_edits right_edits)
          "expected=%s actual=%s" (string_of_int_list expected_keys)
          (string_of_int_list actual_keys))

let laws =
  [
    map_empty_is_empty;
    map_singleton_contains_binding;
    map_of_list_matches_unique_bindings;
    map_of_list_rejects_first_duplicate;
    map_keys_are_unique_by_compare;
    map_lookup_matches_edit_trace;
    map_edits_are_persistent;
    map_set_retains_key_representative;
    map_reinsert_uses_new_key_representative;
    map_physical_noop_preserves_root;
    map_ordered_observations_match_oracle;
    map_map_matches_oracle;
    map_filter_mapi_matches_oracle;
    map_equal_is_extensional;
    map_equal_checks_all_aligned_data;
    map_equal_stops_after_rejection;
    map_diff_events_are_ordered_unique;
    map_diff_reports_physical_changes_only;
    map_diff_uses_map_representatives;
    map_diff_reconstructs_forward;
    map_diff_reconstructs_reverse;
    map_diff_handles_independent_maps;
  ]

let () =
  laws
  |> List.iteri (fun index law ->
         let seed = Random.State.make [| 0xE22; 0x4D4150; index + 1 |] in
         let code =
           QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:seed [ law ]
         in
         if code <> 0 then exit code)
