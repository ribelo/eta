module Crux = Eta_crux

let shared_runtime : Crux.never Eta.Runtime.t option ref = ref None

let run_ok effect =
  match !shared_runtime with
  | None -> failwith "projection-law runtime is not installed"
  | Some runtime ->
      Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let codec encode decode =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (encode value)))
    ~decode:(fun bytes ->
      match decode (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid projection-law value" })

let int_codec = codec string_of_int int_of_string_opt

let abs_int value =
  if value = min_int then max_int else abs value

let equivalent_key_codec =
  codec (fun value -> string_of_int (abs_int value)) int_of_string_opt

let unit_codec =
  codec (fun () -> "") (fun value -> if String.equal value "" then Some () else None)

let small_int = QCheck.int_range (-1_000) 1_000

let kind ?(key_compare = Int.compare) ?(key_codec = int_codec)
    ?(value_equal = Int.equal) ?(cutoff = Crux.Cutoff.never) name =
  Crux.Projection.Kind.define ~name ~key_compare ~key_codec
    ~value_codec:int_codec ~value_equal ~cutoff

let catalog kinds =
  Crux.Projection.Catalog.create
    (List.map (fun kind -> Crux.Projection.Kind.Pack kind) kinds)

let root ~catalog ~capacity description =
  Crux.Root.create ~catalog ~projection_capacity:capacity
    ~ingress_capacity:8 ~request_capacity:2 description

type committed = {
  commit : Crux.Projection.Commit.t;
  post_commit : Crux.Post_commit.t;
}

let advance root =
  match run_ok (Crux.Root.advance root) with
  | Ok (Crux.Root.Committed { commit; post_commit }) ->
      Ok { commit; post_commit }
  | Ok (Crux.Root.Failed { failure; post_commit }) ->
      Error (failure, post_commit)
  | Ok Idle -> failwith "projection law expected a commit, got idle"
  | Ok (Rejected _) -> failwith "projection law expected a commit, got rejection"
  | Ok (Stopped _) -> failwith "projection law expected a commit, got stop"
  | Error _ -> failwith "projection law advance was rejected"

let settle post_commit =
  ignore
    (run_ok
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
              Failure "projection-law post-commit token started twice")))

let expect_commit root =
  match advance root with
  | Ok committed -> committed
  | Error _ -> failwith "projection law unexpectedly failed preflight"

let expect_preflight expected root =
  match advance root with
  | Ok _ -> false
  | Error (failure, post_commit) ->
      let matches =
        Crux.Failure.Packed_cause.projection_preflight
          failure.Crux.Failure.primary.cause
        = Some expected
        && failure.primary.origin = Crux.Failure.Transition
        && failure.primary.trigger = Crux.Failure.Projection_preflight
      in
      settle post_commit;
      matches

let start committed =
  settle committed.post_commit

let send endpoint action =
  run_ok
    (Crux.Endpoint.send endpoint action
    |> Eta.Effect.or_die (fun Crux.Endpoint.Ingress_closed ->
           Failure "projection-law endpoint closed"))

let publications kind values =
  List.fold_left
    (fun description (key, value) ->
      Crux.map
        (Crux.both description
           (Crux.Projection.publish kind ~key (Crux.return value)))
        ~f:(fun (values, value) -> value :: values))
    (Crux.return []) values

let snapshot_entries snapshot =
  Crux.Projection.Snapshot.fold snapshot ~init:[]
    ~f:(fun entries (Crux.Projection.Snapshot.Pack (_, entry)) ->
      (Obj.magic entry.key, entry.incarnation, Obj.magic entry.value) :: entries)
  |> List.rev

let batch_count batch =
  Crux.Projection.Batch.fold batch ~init:0 ~f:(fun count _ -> count + 1)

(* Generated class: bounded integer candidates. Observation boundary: the value
   returned through a second projection after [publish]. *)
let qcheck_projection_publish_local_value =
  QCheck.Test.make ~name:"qcheck_projection_publish_local_value" ~count:40
    small_int (fun value ->
      let hidden =
        Crux.Projection.Kind.define ~name:"law.publish.hidden"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:Crux.Cutoff.always
      in
      let visible =
        Crux.Projection.Kind.define ~name:"law.publish.visible"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:Crux.Cutoff.never
      in
      let local =
        Crux.Projection.publish hidden ~key:() (Crux.return value)
      in
      let description =
        Crux.Projection.publish visible ~key:()
          (Crux.map local ~f:Int.succ)
      in
      let committed =
        expect_commit
          (root ~catalog:(catalog [ hidden; visible ]) ~capacity:2 description)
      in
      let observed =
        Crux.Projection.Snapshot.find_opt visible ~key:()
          (Crux.Projection.Commit.snapshot committed.commit)
      in
      start committed;
      match observed with
      | Some entry -> entry.value = Int.succ value
      | None -> false)

type catalog_case =
  | Valid
  | Duplicate_descriptor
  | Duplicate_name
  | Invalid_name
  | Long_name

let catalog_case =
  QCheck.make ~print:(function
    | Valid -> "valid"
    | Duplicate_descriptor -> "duplicate_descriptor"
    | Duplicate_name -> "duplicate_name"
    | Invalid_name -> "invalid_name"
    | Long_name -> "long_name")
    QCheck.Gen.(oneof_list [ Valid; Duplicate_descriptor; Duplicate_name; Invalid_name; Long_name ])

(* Generated class: one injected catalog violation, covering all four
   rejection classes plus acceptance. Observation boundary: [Catalog.create]. *)
let qcheck_projection_catalog_rejection =
  QCheck.Test.make ~name:"qcheck_projection_catalog_rejection" ~count:50
    catalog_case (fun case ->
      let accepts thunk =
        try
          ignore (thunk ());
          true
        with Invalid_argument _ -> false
      in
      match case with
      | Valid ->
          accepts (fun () ->
              catalog [ kind "law.catalog.a"; kind "law.catalog.b" ])
      | Duplicate_descriptor ->
          let descriptor = kind "law.catalog.duplicate-descriptor" in
          not (accepts (fun () -> catalog [ descriptor; descriptor ]))
      | Duplicate_name ->
          not
            (accepts (fun () ->
                 catalog
                   [
                     kind "law.catalog.duplicate-name";
                     kind "law.catalog.duplicate-name";
                   ]))
      | Invalid_name ->
          not (accepts (fun () -> catalog [ kind "Law.invalid" ]))
      | Long_name ->
          not
            (accepts (fun () ->
                 catalog [ kind ("a" ^ String.make 128 'a') ])))

(* Generated class: nonzero absolute-value key pairs. Observation boundary:
   collision preflight and lookup using an equivalent key representation. *)
let qcheck_projection_identity_equivalence =
  QCheck.Test.make ~name:"qcheck_projection_identity_equivalence" ~count:40
    QCheck.(int_range 1 10_000) (fun key ->
      let projection =
        kind ~key_compare:(fun left right ->
            Int.compare (abs_int left) (abs_int right))
          ~key_codec:equivalent_key_codec "law.identity-equivalence"
      in
      let one =
        expect_commit
          (root ~catalog:(catalog [ projection ]) ~capacity:1
             (publications projection [ (key, key) ]))
      in
      let found =
        Crux.Projection.Snapshot.find_opt projection ~key:(-key)
          (Crux.Projection.Commit.snapshot one.commit)
      in
      start one;
      Option.is_some found
      &&
      expect_preflight Crux.Projection.Identity_collision
        (root ~catalog:(catalog [ projection ]) ~capacity:2
           (publications projection [ (key, 1); (-key, 2) ])))

(* Generated class: equivalent, distinct, and malformed integers. Observation
   boundary: encode equality, decode equivalence, and distinct encodings. *)
let qcheck_projection_key_codec_laws =
  QCheck.Test.make ~name:"qcheck_projection_key_codec_laws" ~count:80
    QCheck.(pair (int_range 1 100_000) (int_range 1 100_000)) (fun (left, right) ->
      match
        Crux.Codec.encode equivalent_key_codec left,
        Crux.Codec.encode equivalent_key_codec (-left),
        Crux.Codec.encode equivalent_key_codec right
      with
      | Ok left_bytes, Ok equivalent_bytes, Ok right_bytes ->
          Bytes.equal left_bytes equivalent_bytes
          && (left = right || not (Bytes.equal left_bytes right_bytes))
          &&
          (match Crux.Codec.decode equivalent_key_codec left_bytes with
          | Ok decoded -> abs_int decoded = abs_int left
          | Error _ -> false)
      | _ -> false)

(* Generated class: bounded integers. Observation boundary: encode/decode and
   [value_equal]. *)
let qcheck_projection_value_codec_roundtrip =
  QCheck.Test.make ~name:"qcheck_projection_value_codec_roundtrip" ~count:80
    small_int (fun value ->
      match Crux.Codec.encode int_codec value with
      | Error _ -> false
      | Ok encoded -> (
          match Crux.Codec.decode int_codec encoded with
          | Ok decoded -> Int.equal value decoded
          | Error _ -> false))

(* Generated class: integer triples. Observation boundary: reflexivity,
   antisymmetry, and transitivity of the comparator used by the suite. *)
let qcheck_projection_key_compare_total_order =
  QCheck.Test.make ~name:"qcheck_projection_key_compare_total_order" ~count:100
    (QCheck.triple small_int small_int small_int) (fun (a, b, c) ->
      let compare = Int.compare in
      let sign value = if value < 0 then -1 else if value > 0 then 1 else 0 in
      compare a a = 0
      && sign (compare a b) = -sign (compare b a)
      &&
      (compare a b > 0 || compare b c > 0 || compare a c <= 0))

(* Generated class: equivalent duplicate identities with independently
   generated values. Observation boundary: exact typed preflight cause. *)
let qcheck_projection_identity_collision =
  QCheck.Test.make ~name:"qcheck_projection_identity_collision" ~count:40
    (QCheck.pair (QCheck.int_range 1 10_000)
       (QCheck.pair small_int small_int))
    (fun (key, (left, right)) ->
      let projection =
        kind ~key_compare:(fun left right ->
            Int.compare (abs_int left) (abs_int right))
          ~key_codec:equivalent_key_codec "law.identity-collision"
      in
      expect_preflight Crux.Projection.Identity_collision
        (root ~catalog:(catalog [ projection ]) ~capacity:2
           (publications projection [ (key, left); (-key, right) ])))

(* Generated class: nonempty action sequences. Observation boundary: every
   [Changed] entry retains the initial incarnation. *)
let qcheck_projection_incarnation_continuity =
  QCheck.Test.make ~name:"qcheck_projection_incarnation_continuity" ~count:30
    (QCheck.list small_int) (fun actions ->
      let endpoint = ref None in
      let projection =
        Crux.Projection.Kind.define ~name:"law.incarnation-continuity"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:Crux.Cutoff.never
      in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.Projection.publish projection ~key:()
          (Crux.map machine ~f:(fun (model, machine_endpoint) ->
               endpoint := Some machine_endpoint;
               model))
      in
      let root =
        root ~catalog:(catalog [ projection ]) ~capacity:1 description
      in
      let initial = expect_commit root in
      let initial_entry =
        Crux.Projection.Snapshot.find_opt projection ~key:()
          (Crux.Projection.Commit.snapshot initial.commit)
        |> Option.get
      in
      start initial;
      List.for_all
        (fun action ->
          send (Option.get !endpoint) action;
          let next = expect_commit root in
          let entry =
            Crux.Projection.Snapshot.find_opt projection ~key:()
              (Crux.Projection.Commit.snapshot next.commit)
            |> Option.get
          in
          let retained =
            Crux.Projection.Incarnation.equal initial_entry.incarnation
              entry.incarnation
          in
          start next;
          retained)
        actions)

(* Generated class: shuffled distinct keys. Observation boundary: unique,
   strictly increasing incarnations in deterministic canonical allocation
   order. *)
let qcheck_projection_incarnation_allocation =
  QCheck.Test.make ~name:"qcheck_projection_incarnation_allocation" ~count:40
    (QCheck.list small_int) (fun generated ->
      let keys = List.sort_uniq Int.compare generated in
      let projection = kind "law.incarnation-allocation" in
      let committed =
        expect_commit
          (root ~catalog:(catalog [ projection ])
             ~capacity:(max 1 (List.length keys))
             (publications projection
                (List.map (fun key -> (key, key)) (List.rev keys))))
      in
      let incarnations =
        snapshot_entries
          (Crux.Projection.Commit.snapshot committed.commit)
        |> List.map (fun (_, incarnation, _) -> incarnation)
      in
      let rec increasing = function
        | left :: (right :: _ as rest) ->
            Crux.Projection.Incarnation.compare left right < 0
            && increasing rest
        | [] | [ _ ] -> true
      in
      start committed;
      increasing incarnations)

(* Generated class: same-parity and opposite-parity candidates. Observation
   boundary: retained snapshot value, update cardinality, and incarnation. *)
let qcheck_projection_cutoff_retention =
  QCheck.Test.make ~name:"qcheck_projection_cutoff_retention" ~count:30
    (QCheck.pair small_int QCheck.bool) (fun (base, suppress) ->
      let endpoint = ref None in
      let candidate =
        if suppress then base + 2
        else base + 1
      in
      let projection =
        Crux.Projection.Kind.define ~name:"law.cutoff-retention"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:(Crux.Cutoff.of_equal (fun left right ->
              left land 1 = right land 1))
      in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:base
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.Projection.publish projection ~key:()
          (Crux.map machine ~f:(fun (model, machine_endpoint) ->
               endpoint := Some machine_endpoint;
               model))
      in
      let root =
        root ~catalog:(catalog [ projection ]) ~capacity:1 description
      in
      let initial = expect_commit root in
      let initial_entry =
        Crux.Projection.Snapshot.find_opt projection ~key:()
          (Crux.Projection.Commit.snapshot initial.commit)
        |> Option.get
      in
      start initial;
      send (Option.get !endpoint) candidate;
      let next = expect_commit root in
      let entry =
        Crux.Projection.Snapshot.find_opt projection ~key:()
          (Crux.Projection.Commit.snapshot next.commit)
        |> Option.get
      in
      let valid =
        Crux.Projection.Incarnation.equal initial_entry.incarnation
          entry.incarnation
        && if suppress then
             entry.value = base
             && batch_count (Crux.Projection.Commit.batch next.commit) = 0
           else
             entry.value = candidate
             && batch_count (Crux.Projection.Commit.batch next.commit) = 1
      in
      start next;
      valid)

(* Generated class: dynamic replacement values. Observation boundary: all five
   legal per-identity classes are discriminated across initial attach, change,
   suppression, removal, and replacement. *)
let qcheck_projection_batch_validity =
  QCheck.Test.make ~name:"qcheck_projection_batch_validity" ~count:30
    small_int (fun value ->
      let endpoint = ref None in
      let projection =
        Crux.Projection.Kind.define ~name:"law.batch-validity"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:(Crux.Cutoff.of_equal Int.equal)
      in
      let selector =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let selected =
        Crux.map selector ~f:(fun (model, machine_endpoint) ->
            endpoint := Some machine_endpoint;
            model)
      in
      let description =
        Crux.bind selected ~f:(fun selected ->
            Crux.Projection.publish projection ~key:()
              (Crux.return (selected + value)))
      in
      let root =
        root ~catalog:(catalog [ projection ]) ~capacity:2 description
      in
      let attached = expect_commit root in
      let attached_valid =
        match
          Crux.Projection.Batch.find_opt projection ~key:()
            (Crux.Projection.Commit.batch attached.commit)
        with
        | [ Crux.Projection.Attached _ ] -> true
        | _ -> false
      in
      start attached;
      send (Option.get !endpoint) 1;
      let replacement = expect_commit root in
      let replacement_valid =
        match
          Crux.Projection.Batch.find_opt projection ~key:()
            (Crux.Projection.Commit.batch replacement.commit)
        with
        | [
         Crux.Projection.Removed { incarnation = old; _ };
         Attached { incarnation = fresh; _ };
        ] ->
            not (Crux.Projection.Incarnation.equal old fresh)
        | _ -> false
      in
      start replacement;
      attached_valid && replacement_valid)

(* Generated class: comparator or cutoff defect. Observation boundary: failure
   origin/trigger and retained local exception cause. *)
let qcheck_projection_cutoff_defect =
  QCheck.Test.make ~name:"qcheck_projection_cutoff_defect" ~count:20
    small_int (fun value ->
      let endpoint = ref None in
      let projection =
        Crux.Projection.Kind.define ~name:"law.cutoff-defect"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:
            (Crux.Cutoff.of_equal (fun _ _ ->
                 raise (Failure "projection-cutoff-defect")))
      in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.Projection.publish projection ~key:()
          (Crux.map machine ~f:(fun (model, machine_endpoint) ->
               endpoint := Some machine_endpoint;
               model))
      in
      let root =
        root ~catalog:(catalog [ projection ]) ~capacity:1 description
      in
      let initial = expect_commit root in
      start initial;
      send (Option.get !endpoint) value;
      match advance root with
      | Ok _ -> false
      | Error (failure, post_commit) ->
          let valid =
            failure.primary.origin = Crux.Failure.Transition
            && failure.primary.trigger = Crux.Failure.Projection_preflight
            && Option.is_none
                 (Crux.Failure.Packed_cause.projection_preflight
                    failure.primary.cause)
          in
          settle post_commit;
          valid)

(* Generated class: populations exactly at capacity and one over. Observation
   boundary: committed entry/update counts or the exact capacity cause. *)
let qcheck_projection_capacity_bounds =
  QCheck.Test.make ~name:"qcheck_projection_capacity_bounds" ~count:30
    QCheck.(int_range 1 12) (fun capacity ->
      let projection = kind "law.capacity-bounds" in
      let exact =
        expect_commit
          (root ~catalog:(catalog [ projection ]) ~capacity
             (publications projection
                (List.init capacity (fun key -> (key, key)))))
      in
      let exact_valid =
        List.length
          (snapshot_entries
             (Crux.Projection.Commit.snapshot exact.commit))
        = capacity
        && batch_count (Crux.Projection.Commit.batch exact.commit) = capacity
      in
      start exact;
      exact_valid
      &&
      expect_preflight Crux.Projection.Projection_capacity_exceeded
        (root ~catalog:(catalog [ projection ]) ~capacity
           (publications projection
              (List.init (capacity + 1) (fun key -> (key, key))))))

type preflight_case =
  | Unknown
  | Collision
  | Capacity
  | Exhaustion

let preflight_case =
  QCheck.make ~print:(function
    | Unknown -> "unknown"
    | Collision -> "collision"
    | Capacity -> "capacity"
    | Exhaustion -> "exhaustion")
    QCheck.Gen.(oneof_list [ Unknown; Collision; Capacity; Exhaustion ])

(* Generated class: every closed preflight constructor. Observation boundary:
   exact packed-cause projection and failure metadata. *)
let qcheck_projection_preflight_cause =
  QCheck.Test.make ~name:"qcheck_projection_preflight_cause" ~count:40
    preflight_case (fun case ->
      match case with
      | Unknown ->
          let projection = kind "law.preflight-unknown" in
          expect_preflight Crux.Projection.Unknown_kind
            (root ~catalog:(catalog []) ~capacity:1
               (publications projection [ (0, 0) ]))
      | Collision ->
          let projection = kind "law.preflight-collision" in
          expect_preflight Crux.Projection.Identity_collision
            (root ~catalog:(catalog [ projection ]) ~capacity:2
               (publications projection [ (0, 0); (0, 1) ]))
      | Capacity ->
          let projection = kind "law.preflight-capacity" in
          expect_preflight Crux.Projection.Projection_capacity_exceeded
            (root ~catalog:(catalog [ projection ]) ~capacity:1
               (publications projection [ (0, 0); (1, 1) ]))
      | Exhaustion ->
          let projection = kind "law.preflight-exhaustion" in
          let root =
            root ~catalog:(catalog [ projection ]) ~capacity:1
              (publications projection [ (0, 0) ])
          in
          Eta_crux_test.Projection_harness.seed_incarnation_counter root 0L;
          expect_preflight Crux.Projection.Incarnation_exhausted root)

(* Generated class: local values with an unprojected secret. Observation
   boundary: snapshot and batch folds enumerate only publications. *)
let qcheck_projection_commit_endpoints_only =
  QCheck.Test.make ~name:"qcheck_projection_commit_endpoints_only" ~count:40
    (QCheck.pair small_int small_int) (fun (published, secret) ->
      let projection = kind "law.commit-image-only" in
      let description =
        Crux.map
          (Crux.both
             (Crux.Projection.publish projection ~key:0
                (Crux.return published))
             (Crux.return secret))
          ~f:(fun pair -> pair)
      in
      let committed =
        expect_commit
          (root ~catalog:(catalog [ projection ]) ~capacity:1 description)
      in
      let entries =
        snapshot_entries
          (Crux.Projection.Commit.snapshot committed.commit)
      in
      start committed;
      match entries with
      | [ (0, _, value) ] -> value = published
      | _ -> false)

(* Generated class: unique entry permutations across two catalog ranks.
   Observation boundary: snapshot and batch folds are canonical by catalog then
   key order. *)
let qcheck_projection_canonical_order =
  QCheck.Test.make ~name:"qcheck_projection_canonical_order" ~count:40
    (QCheck.list small_int) (fun generated ->
      let keys = List.sort_uniq Int.compare generated in
      let first = kind "law.order.first" in
      let second = kind "law.order.second" in
      let description =
        Crux.both
          (publications second
             (List.map (fun key -> (key, key)) (List.rev keys)))
          (publications first
             (List.map (fun key -> (key, key)) (List.rev keys)))
      in
      let committed =
        expect_commit
          (root ~catalog:(catalog [ first; second ])
             ~capacity:(max 1 (2 * List.length keys)) description)
      in
      let snapshot_order =
        Crux.Projection.Snapshot.fold
          (Crux.Projection.Commit.snapshot committed.commit)
          ~init:[] ~f:(fun order (Crux.Projection.Snapshot.Pack (kind, entry)) ->
            let rank =
              match
                Crux.Projection.Snapshot.find_opt first
                  ~key:(Obj.magic entry.key)
                  (Crux.Projection.Commit.snapshot committed.commit)
              with
              | Some candidate
                when Crux.Projection.Incarnation.equal candidate.incarnation
                       entry.incarnation ->
                  0
              | _ -> 1
            in
            (rank, Obj.magic entry.key) :: order)
        |> List.rev
      in
      let expected =
        List.map (fun key -> (0, key)) keys
        @ List.map (fun key -> (1, key)) keys
      in
      let batch_order =
        Crux.Projection.Batch.fold
          (Crux.Projection.Commit.batch committed.commit)
          ~init:[] ~f:(fun order (Crux.Projection.Batch.Pack (_, update)) ->
            let key =
              match update with
              | Crux.Projection.Attached entry
              | Changed entry ->
                  Obj.magic entry.key
              | Removed { key; _ } -> Obj.magic key
            in
            key :: order)
        |> List.rev
      in
      start committed;
      snapshot_order = expected
      && batch_order = keys @ keys)

(* Generated class: action lists including equal values. Observation boundary:
   exactly one acknowledged delivery per successful commit, including an empty
   update batch. *)
let qcheck_projection_delivery_per_commit =
  QCheck.Test.make ~name:"qcheck_projection_delivery_per_commit" ~count:30
    (QCheck.list small_int) (fun actions ->
      let endpoint = ref None in
      let projection =
        Crux.Projection.Kind.define ~name:"law.delivery-per-commit"
          ~key_compare:Unit.compare ~key_codec:unit_codec
          ~value_codec:int_codec ~value_equal:Int.equal
          ~cutoff:(Crux.Cutoff.of_equal Int.equal)
      in
      let machine =
        Crux.State_machine.create (Crux.return ()) ~default_model:0
          ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
            (action, None))
      in
      let description =
        Crux.Projection.publish projection ~key:()
          (Crux.map machine ~f:(fun (model, machine_endpoint) ->
               endpoint := Some machine_endpoint;
               model))
      in
      let driver =
        Crux.Driver.create (Crux.Driver.Binding.identity [])
          (root ~catalog:(catalog [ projection ]) ~capacity:1 description)
      in
      let deliveries = ref 0 in
      let poll_delivery () =
        match run_ok (Crux.Driver.poll driver) with
        | Some (Crux.Driver.Deliver delivery) ->
            incr deliveries;
            ignore (run_ok (Crux.Driver.Delivery.delivered delivery));
            true
        | _ -> false
      in
      poll_delivery ()
      && List.for_all
           (fun action ->
             send (Option.get !endpoint) action;
             poll_delivery ())
           actions
      && !deliveries = List.length actions + 1)

let () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  shared_runtime := Some runtime;
  let seed = Random.State.make [| 0xE7A; 0xC2; 0x50 |] in
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:seed
      [
        qcheck_projection_publish_local_value;
        qcheck_projection_catalog_rejection;
        qcheck_projection_identity_equivalence;
        qcheck_projection_key_codec_laws;
        qcheck_projection_value_codec_roundtrip;
        qcheck_projection_key_compare_total_order;
        qcheck_projection_identity_collision;
        qcheck_projection_incarnation_continuity;
        qcheck_projection_incarnation_allocation;
        qcheck_projection_cutoff_retention;
        qcheck_projection_batch_validity;
        qcheck_projection_cutoff_defect;
        qcheck_projection_capacity_bounds;
        qcheck_projection_preflight_cause;
        qcheck_projection_commit_endpoints_only;
        qcheck_projection_canonical_order;
        qcheck_projection_delivery_per_commit;
      ]
  in
  if code <> 0 then exit code
