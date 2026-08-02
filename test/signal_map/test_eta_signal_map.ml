module Int_map = Eta_signal_map.Map.Make (Int)

let test_empty_and_singleton () =
  let empty = Int_map.empty in
  Alcotest.(check bool) "empty" true (Int_map.is_empty empty);
  Alcotest.(check int) "empty cardinal" 0 (Int_map.cardinal empty);
  let singleton = Int_map.singleton 7 "seven" in
  Alcotest.(check bool) "singleton nonempty" false
    (Int_map.is_empty singleton);
  Alcotest.(check int) "singleton cardinal" 1 (Int_map.cardinal singleton);
  Alcotest.(check (option string)) "singleton lookup" (Some "seven")
    (Int_map.find_opt 7 singleton)

type key = {
  rank : int;
  tag : string;
}

module Key_map = Eta_signal_map.Map.Make (struct
  type t = key

  let compare left right = Int.compare left.rank right.rank
end)

let test_persistent_edits_keep_representative () =
  let first = { rank = 3; tag = "first" } in
  let equal_key = { rank = 3; tag = "second" } in
  let original = Key_map.singleton first "old" in
  let changed = Key_map.set equal_key "new" original in
  Alcotest.(check (option string)) "old snapshot" (Some "old")
    (Key_map.find_opt first original);
  Alcotest.(check (option string)) "new snapshot" (Some "new")
    (Key_map.find_opt first changed);
  let stored_key, stored_data = List.hd (Key_map.to_list changed) in
  Alcotest.(check bool) "representative retained" true (stored_key == first);
  Alcotest.(check string) "data replaced" "new" stored_data;
  let unchanged = Key_map.set equal_key stored_data changed in
  Alcotest.(check bool) "same data keeps root" true (unchanged == changed);
  let removed = Key_map.remove equal_key changed in
  Alcotest.(check bool) "removed" true (Key_map.is_empty removed);
  Alcotest.(check bool) "absent removal keeps root" true
    (Key_map.remove equal_key removed == removed)

let test_of_list_rejects_first_duplicate () =
  let first = { rank = 1; tag = "first" } in
  let duplicate = { rank = 1; tag = "duplicate" } in
  let later = { rank = 2; tag = "later" } in
  match
    Key_map.of_list
      [ (later, "later"); (first, "first"); (duplicate, "duplicate") ]
  with
  | Error (`Duplicate_key key) ->
      Alcotest.(check bool) "exact duplicate occurrence" true (key == duplicate)
  | Ok _ -> Alcotest.fail "of_list accepted a duplicate key"

let test_transforms_preserve_physical_noop () =
  let map =
    match Int_map.of_list [ (2, "two"); (1, "one"); (3, "three") ] with
    | Ok map -> map
    | Error _ -> Alcotest.fail "unique input was rejected"
  in
  let mapped = Int_map.map Fun.id map in
  Alcotest.(check bool) "map physical no-op" true (mapped == map);
  let filtered = Int_map.filter_mapi (fun _ data -> Some data) map in
  Alcotest.(check bool) "filter physical no-op" true (filtered == map);
  Alcotest.(check (list (pair int string))) "filtered values"
    [ (1, "one"); (3, "three") ]
    (Int_map.filter_mapi
       (fun key data -> if key = 2 then None else Some data)
       map
    |> Int_map.to_list)

let test_equal_checks_physical_root_extensionally () =
  let map =
    match Int_map.of_list [ (1, "one"); (2, "two"); (3, "three") ] with
    | Ok map -> map
    | Error _ -> Alcotest.fail "unique input was rejected"
  in
  let calls = ref 0 in
  Alcotest.(check bool) "same root equal" true
    (Int_map.equal
       (fun left right ->
         incr calls;
         String.equal left right)
       map map);
  Alcotest.(check int) "all aligned pairs checked" 3 !calls;
  let rejected = ref false in
  Alcotest.(check bool) "predicate rejection" false
    (Int_map.equal
       (fun left _right ->
         if !rejected then Alcotest.fail "predicate called after rejection";
         if String.equal left "two" then (
           rejected := true;
           false)
         else true)
       map map)

let test_symmetric_diff_is_ordered_and_physical () =
  let shared = ref 10 in
  let old_data = ref 20 in
  let new_data = ref 20 in
  let left =
    match Int_map.of_list [ (1, shared); (2, old_data); (4, ref 40) ] with
    | Ok map -> map
    | Error _ -> Alcotest.fail "unique input was rejected"
  in
  let right =
    left |> Int_map.set 2 new_data |> Int_map.remove 4 |> Int_map.set 3 (ref 30)
  in
  let events =
    Int_map.fold_symmetric_diff left right ~init:[]
      ~f:(fun events key change -> (key, change) :: events)
    |> List.rev
  in
  match events with
  | [
   (2, Eta_signal_map.Map.Changed (actual_old, actual_new));
   (3, Eta_signal_map.Map.Right right_only);
   (4, Eta_signal_map.Map.Left left_only);
  ] ->
      Alcotest.(check bool) "old object" true (actual_old == old_data);
      Alcotest.(check bool) "new object" true (actual_new == new_data);
      Alcotest.(check int) "right data" 30 !right_only;
      Alcotest.(check int) "left data" 40 !left_only
  | _ -> Alcotest.fail "unexpected symmetric diff"

let collect_diff left right =
  Int_map.fold_symmetric_diff left right ~init:[]
    ~f:(fun events key change -> (key, change) :: events)
  |> List.rev

let test_map_diff_empty () =
  Alcotest.(check int) "no events" 0
    (List.length (collect_diff Int_map.empty Int_map.empty))

let test_map_diff_left_only () =
  match collect_diff (Int_map.singleton 1 "left") Int_map.empty with
  | [ (1, Eta_signal_map.Map.Left "left") ] -> ()
  | _ -> Alcotest.fail "expected one left event"

let test_map_diff_right_only () =
  match collect_diff Int_map.empty (Int_map.singleton 1 "right") with
  | [ (1, Eta_signal_map.Map.Right "right") ] -> ()
  | _ -> Alcotest.fail "expected one right event"

let test_map_diff_physical_same () =
  let value = ref 1 in
  let left = Int_map.singleton 1 value in
  let right = Int_map.singleton 1 value in
  Alcotest.(check int) "no events" 0 (List.length (collect_diff left right))

let test_map_diff_physical_changed () =
  let left_value = ref 1 in
  let right_value = ref 1 in
  match
    collect_diff (Int_map.singleton 1 left_value)
      (Int_map.singleton 1 right_value)
  with
  | [ (1, Eta_signal_map.Map.Changed (left, right)) ]
    when left == left_value && right == right_value ->
      ()
  | _ -> Alcotest.fail "expected one physical changed event"

let test_map_diff_mixed_ordered () =
  let shared = ref 0 in
  let left =
    Int_map.empty |> Int_map.set 1 (ref 1) |> Int_map.set 2 shared
    |> Int_map.set 4 (ref 4)
  in
  let right =
    Int_map.empty |> Int_map.set 1 (ref 10) |> Int_map.set 2 shared
    |> Int_map.set 3 (ref 3)
  in
  match collect_diff left right with
  | [
   (1, Eta_signal_map.Map.Changed _);
   (3, Eta_signal_map.Map.Right _);
   (4, Eta_signal_map.Map.Left _);
  ] ->
      ()
  | _ -> Alcotest.fail "expected ordered mixed events"

let () =
  Alcotest.run "eta_signal_map"
    [
      ( "map",
        [
          Alcotest.test_case "empty and singleton" `Quick
            test_empty_and_singleton;
          Alcotest.test_case "persistent edits keep representative" `Quick
            test_persistent_edits_keep_representative;
          Alcotest.test_case "of_list rejects first duplicate" `Quick
            test_of_list_rejects_first_duplicate;
          Alcotest.test_case "transforms preserve physical no-op" `Quick
            test_transforms_preserve_physical_noop;
          Alcotest.test_case "equal checks physical root extensionally" `Quick
            test_equal_checks_physical_root_extensionally;
          Alcotest.test_case "symmetric diff is ordered and physical" `Quick
            test_symmetric_diff_is_ordered_and_physical;
          Alcotest.test_case "map_diff_empty" `Quick test_map_diff_empty;
          Alcotest.test_case "map_diff_left_only" `Quick test_map_diff_left_only;
          Alcotest.test_case "map_diff_right_only" `Quick test_map_diff_right_only;
          Alcotest.test_case "map_diff_physical_same" `Quick
            test_map_diff_physical_same;
          Alcotest.test_case "map_diff_physical_changed" `Quick
            test_map_diff_physical_changed;
          Alcotest.test_case "map_diff_mixed_ordered" `Quick
            test_map_diff_mixed_ordered;
        ] );
    ]
