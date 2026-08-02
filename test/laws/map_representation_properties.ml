module Subject = Eta_signal_map_kernel.Make (Int)

type data = {
  value : int;
  tag : int;
}

type edit =
  | Set of int * int
  | Remove of int
  | Update of int * int option

let data value tag = { value; tag }

let string_of_edit = function
  | Set (key, value) -> Printf.sprintf "set(%d,%d)" key value
  | Remove key -> Printf.sprintf "remove(%d)" key
  | Update (key, value) ->
      Printf.sprintf "update(%d,%s)" key
        (match value with None -> "none" | Some value -> string_of_int value)

let string_of_edits edits =
  edits |> List.map string_of_edit |> String.concat ";" |> Printf.sprintf "[%s]"

let edit_gen =
  let open QCheck.Gen in
  oneof_weighted
    [
      (3, map2 (fun key value -> Set (key, value)) (int_range (-255) 255) (int_range (-512) 512));
      (1, map (fun key -> Remove key) (int_range (-255) 255));
      (2, map3 (fun key keep value -> Update (key, if keep then Some value else None))
            (int_range (-255) 255) bool (int_range (-512) 512));
    ]

let traces =
  QCheck.make ~print:string_of_edits
    QCheck.Gen.(list_size (int_range 1 512) edit_gen)

let fail name generated format =
  Printf.ksprintf
    (fun detail ->
      QCheck.Test.fail_reportf
        "property=%s seed=[0xE22;0x4D4150;n] class=%s counterexample=%s\n%s"
        name name generated detail)
    format

let property name arbitrary f =
  QCheck.Test.make ~name ~count:1_000 arbitrary (fun value -> f value; true)

let dense count =
  List.init count (fun key -> (key, data key key))
  |> List.fold_left
       (fun map (key, data) -> Subject.set key data map)
       Subject.empty

let check name generated map =
  match Subject.check_invariants map with
  | Ok () -> ()
  | Error error -> fail name generated "invariant error: %s" error

(* smmap-t9g9 *)
let map_kernel_invariants_survive_edits =
  property "map_kernel_invariants_survive_edits" traces (fun edits ->
      if Subject.node_count Subject.empty <> 0 then
        fail "map_kernel_invariants_survive_edits" (string_of_edits edits)
          "empty contains a node";
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
      let map = ref Subject.empty in
      List.iteri
        (fun index edit ->
          map :=
            (match edit with
            | Set (key, value) -> Subject.set key (data value index) !map
            | Remove key -> Subject.remove key !map
            | Update (key, value) ->
                Subject.update key
                  (fun _ -> Option.map (fun value -> data value index) value)
                  !map);
          check "map_kernel_invariants_survive_edits" (string_of_edits edits) !map)
        edits)

(* smmap-inyq *)
let map_edits_retain_unchanged_subtrees =
  property "map_edits_retain_unchanged_subtrees" QCheck.int (fun value ->
      let map = dense 63 in
      let changed = Subject.set 0 (data value 10_000) map in
      check "map_edits_retain_unchanged_subtrees" (string_of_int value) changed;
      if Subject.shared_node_count map changed = 0 then
        fail "map_edits_retain_unchanged_subtrees" (string_of_int value)
          "the edit retained no unchanged node")

(* smmap-86dk *)
let map_map_preserves_noop_root =
  property "map_map_preserves_noop_root" QCheck.(int_range 1 255) (fun count ->
      let map = dense count in
      if Subject.map Fun.id map != map then
        fail "map_map_preserves_noop_root" (string_of_int count)
          "the root changed")

(* smmap-2yd7 *)
let map_map_retains_unchanged_nodes =
  property "map_map_retains_unchanged_nodes" QCheck.int (fun value ->
      let map = dense 63 in
      let changed =
        Subject.map
          (fun item -> if item.value = 0 then data value 20_000 else item)
          map
      in
      if Subject.shared_node_count map changed = 0 then
        fail "map_map_retains_unchanged_nodes" (string_of_int value)
          "the transform retained no unchanged node")

(* smmap-86dk *)
let map_filter_mapi_preserves_noop_root =
  property "map_filter_mapi_preserves_noop_root" QCheck.(int_range 1 255)
    (fun count ->
      let map = dense count in
      if Subject.filter_mapi (fun _ data -> Some data) map != map then
        fail "map_filter_mapi_preserves_noop_root" (string_of_int count)
          "the root changed")

(* smmap-2yd7 *)
let map_filter_mapi_retains_unchanged_nodes =
  property "map_filter_mapi_retains_unchanged_nodes" QCheck.int (fun value ->
      let map = dense 63 in
      let divisor = 2 + abs (value mod 7) in
      let broadly_filtered =
        Subject.filter_mapi
          (fun key item -> if key mod divisor = 0 then None else Some item)
          map
      in
      check "map_filter_mapi_retains_unchanged_nodes" (string_of_int value)
        broadly_filtered;
      let changed =
        Subject.filter_mapi
          (fun key item ->
            if key = 0 then None
            else if key = 1 then Some (data value 30_000)
            else Some item)
          map
      in
      check "map_filter_mapi_retains_unchanged_nodes" (string_of_int value) changed;
      if Subject.shared_node_count map changed = 0 then
        fail "map_filter_mapi_retains_unchanged_nodes" (string_of_int value)
          "the transform retained no unchanged node")

(* smdiff-91zh *)
let map_singleton_starts_fresh_ancestry =
  property "map_singleton_starts_fresh_ancestry" QCheck.(pair int int)
    (fun (key, value) ->
      let item = data value 1 in
      let left = Subject.singleton key item in
      let right = Subject.singleton key item in
      if Subject.node_count left <> 1 || Subject.node_count right <> 1 then
        fail "map_singleton_starts_fresh_ancestry"
          (Printf.sprintf "%d,%d" key value)
          "singleton node count differs from one";
      if Subject.shared_node_count left right <> 0 then
        fail "map_singleton_starts_fresh_ancestry"
          (Printf.sprintf "%d,%d" key value)
          "fresh singletons share a node")

(* smdiff-91zh *)
let map_of_list_severs_ancestry =
  property "map_of_list_severs_ancestry" QCheck.(int_range 1 255) (fun count ->
      let source = dense count in
      match Subject.of_list (Subject.to_list source) with
      | Error _ ->
          fail "map_of_list_severs_ancestry" (string_of_int count)
            "unique bindings were rejected"
      | Ok rebuilt ->
          if Subject.shared_node_count source rebuilt <> 0 then
            fail "map_of_list_severs_ancestry" (string_of_int count)
              "of_list retained source ancestry")

let laws =
  [
    map_kernel_invariants_survive_edits;
    map_edits_retain_unchanged_subtrees;
    map_map_preserves_noop_root;
    map_map_retains_unchanged_nodes;
    map_filter_mapi_preserves_noop_root;
    map_filter_mapi_retains_unchanged_nodes;
    map_singleton_starts_fresh_ancestry;
    map_of_list_severs_ancestry;
  ]

let () =
  laws
  |> List.iteri (fun index law ->
         let seed = Random.State.make [| 0xE22; 0x4D4150; index + 23 |] in
         let code =
           QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:seed [ law ]
         in
         if code <> 0 then exit code)
