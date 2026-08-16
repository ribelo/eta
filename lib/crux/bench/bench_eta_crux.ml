module Crux = Eta_crux

let unit_codec =
  Crux.Codec.make ~encode:(fun () -> Ok Bytes.empty)
    ~decode:(fun bytes ->
      if Bytes.length bytes = 0 then Ok ()
      else Error { Crux.Codec.message = "invalid unit key" })

type 'value projection = {
  kind : (unit, 'value) Crux.Projection.Kind.t;
  catalog : Crux.Projection.Catalog.t;
}

let projection ~name codec =
  let kind =
    Crux.Projection.Kind.define ~name ~key_compare:Unit.compare
      ~key_codec:unit_codec ~value_codec:codec
      ~value_equal:(fun _ _ -> false) ~cutoff:Crux.Cutoff.never
  in
  {
    kind;
    catalog =
      Crux.Projection.Catalog.create
        [ Crux.Projection.Kind.Pack kind ];
  }

let projection_root projection ~ingress_capacity ~request_capacity
    description =
  Crux.Root.create ~catalog:projection.catalog ~projection_capacity:1
    ~ingress_capacity ~request_capacity
    (Crux.Projection.publish projection.kind ~key:() description)

let projection_delivery_value projection delivery =
  match delivery with
  | Crux.Projection.Bootstrap snapshot -> (
      match
        Crux.Projection.Snapshot.find_opt projection.kind ~key:() snapshot
      with
      | None -> None
      | Some entry -> Some entry.value)
  | Updates batch ->
      let updates =
        Crux.Projection.Batch.find_opt projection.kind ~key:() batch
      in
      List.find_map
        (function
          | Crux.Projection.Attached entry
          | Changed entry ->
              Some entry.value
          | Removed _ -> None)
        updates

let projection_commit_value projection commit =
  match
    Crux.Projection.Snapshot.find_opt projection.kind ~key:()
      (Crux.Projection.Commit.snapshot commit)
  with
  | None -> None
  | Some entry -> Some entry.value

let opaque_projection =
  projection ~name:"benchmark.opaque"
    (Crux.Codec.make ~encode:(fun _ -> Ok Bytes.empty)
       ~decode:(fun _ ->
         Error { Crux.Codec.message = "opaque benchmark projection" }))

let opaque_root ~ingress_capacity ~request_capacity description =
  projection_root opaque_projection ~ingress_capacity ~request_capacity
    (Crux.map description ~f:Obj.repr)

let opaque_delivery_value delivery =
  projection_delivery_value opaque_projection delivery
  |> Option.map Obj.obj

let opaque_commit_value commit =
  projection_commit_value opaque_projection commit
  |> Option.map Obj.obj

let projection_content_value = function
  | Crux.Wire.Frame.Bootstrap (entry :: _) -> entry.value
  | Updates updates ->
      updates
      |> List.find_map (function
           | Crux.Wire.Frame.Attached entry
           | Changed entry ->
               Some entry.value
           | Removed _ -> None)
      |> Option.get
  | Bootstrap [] ->
      invalid_arg "benchmark expected a nonempty projection frame"

let failf format = Printf.ksprintf failwith format
let cleanup_actions = ref []
let wire_operations = ref 0

type projection_stats = {
  mutable commits : int;
  mutable deliveries : int;
  mutable batch_records : int;
  mutable encoded_entries : int;
  mutable encoded_bytes : int;
  mutable cutoff_calls : int;
  mutable key_compare_calls : int;
  mutable bootstrap_entries : int;
}

type projection_absent_observation = {
  mutable commits : int;
  mutable deliveries : int;
  mutable batch_records : int;
  mutable encoded_entries : int;
  mutable encoded_bytes : int;
  mutable cutoff_calls : int;
  mutable bootstrap_entries : int;
}

let projection_stats () =
  {
    commits = 0;
    deliveries = 0;
    batch_records = 0;
    encoded_entries = 0;
    encoded_bytes = 0;
    cutoff_calls = 0;
    key_compare_calls = 0;
    bootstrap_entries = 0;
  }

let reset_projection_stats (stats : projection_stats) =
  stats.commits <- 0;
  stats.deliveries <- 0;
  stats.batch_records <- 0;
  stats.encoded_entries <- 0;
  stats.encoded_bytes <- 0;
  stats.cutoff_calls <- 0;
  stats.key_compare_calls <- 0;
  stats.bootstrap_entries <- 0

let active_projection_stats = ref None

let projection_entry_bytes
    (entry : Crux.Wire.Frame.projection_entry) =
  Bytes.length entry.key + Bytes.length entry.value

let record_projection_frame (stats : projection_stats) = function
  | Crux.Wire.Frame.Projection_deliver
      { content = Updates updates; _ } ->
      stats.batch_records <-
        stats.batch_records + List.length updates;
      stats.encoded_entries <-
        stats.encoded_entries + List.length updates;
      List.iter
        (function
          | Crux.Wire.Frame.Attached entry
          | Changed entry ->
              stats.encoded_bytes <-
                stats.encoded_bytes
                + projection_entry_bytes entry
          | Removed { key; _ } ->
              stats.encoded_bytes <-
                stats.encoded_bytes + Bytes.length key)
        updates
  | Projection_deliver { content = Bootstrap entries; _ } ->
      stats.bootstrap_entries <-
        stats.bootstrap_entries + List.length entries;
      stats.encoded_entries <-
        stats.encoded_entries + List.length entries;
      List.iter
        (fun entry ->
          stats.encoded_bytes <-
            stats.encoded_bytes + projection_entry_bytes entry)
        entries
  | _ -> ()

module Counting_format = struct
  let encode frame =
    incr wire_operations;
    let encoded = Eta_crux_json.Format.encode frame in
    Option.iter
      (fun stats -> record_projection_frame stats frame)
      !active_projection_stats;
    encoded

  let decode bytes =
    incr wire_operations;
    Eta_crux_json.Format.decode bytes
end

let register_cleanup cleanup =
  cleanup_actions := cleanup :: !cleanup_actions

let run_ok runtime eff =
  Eta.Runtime.run runtime eff
  |> Eta_test.Expect.expect_ok

let send runtime endpoint action =
  run_ok runtime
    (Crux.Endpoint.send endpoint action
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed ->
             Failure "benchmark ingress closed"))

let answer_delivery runtime delivery =
  (match
     run_ok runtime (Crux.Driver.Delivery.delivered delivery)
   with
  | Ok () -> ()
  | Error Crux.Driver.Delivery.Already_completed ->
      failwith "benchmark delivery answered twice");
  Option.iter
    (fun (stats : projection_stats) ->
      stats.deliveries <- stats.deliveries + 1)
    !active_projection_stats

let poll_delivery runtime driver =
  match run_ok runtime (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Deliver delivery) -> delivery
  | Some _ | None -> failwith "benchmark expected delivery"

let stop_driver runtime driver =
  Crux.Driver.request_stop driver;
  let rec settle attempts =
    if attempts = 0 then
      failwith "benchmark driver did not settle"
    else
      match run_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Closed _) -> ()
      | Some (Crux.Driver.Deliver delivery) ->
          answer_delivery runtime delivery;
          settle (attempts - 1)
      | Some (Crux.Driver.Request event) ->
          ignore
            (run_ok runtime
               (Crux.Request.Driver_event.accepted event));
          settle (attempts - 1)
      | Some (Crux.Driver.Rejected _)
      | Some (Crux.Driver.Crash_detected _) ->
          settle (attempts - 1)
      | None ->
          ignore (run_ok runtime Eta.Effect.yield);
          settle (attempts - 1)
  in
  settle 1_000

let setup_identity runtime description =
  let root =
    opaque_root ~ingress_capacity:2 ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let initial = poll_delivery runtime driver in
  answer_delivery runtime initial;
  ( driver,
    opaque_delivery_value
      (Crux.Driver.Delivery.projection initial)
    |> Option.get )

let make_action_workload runtime =
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let driver, (_, endpoint) = setup_identity runtime machine in
  fun () ->
    send runtime endpoint 1;
    let delivery = poll_delivery runtime driver in
    answer_delivery runtime delivery

let make_unchanged_workload runtime =
  let projections = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action:_ ->
        (model, None))
  in
  let projected =
    Crux.cutoff (Crux.map machine ~f:fst)
      ~cutoff:(Crux.Cutoff.of_equal Int.equal)
    |> Crux.map ~f:(fun model ->
           incr projections;
           model)
  in
  let driver, ((_, endpoint), _) =
    setup_identity runtime (Crux.both machine projected)
  in
  fun () ->
    let before = !projections in
    send runtime endpoint ();
    let delivery = poll_delivery runtime driver in
    answer_delivery runtime delivery;
    if !projections <> before then
      failwith "equal model recomputed a dependent projection"

module Counting_order = struct
  type t = int

  let comparisons = ref 0

  let compare left right =
    incr comparisons;
    Int.compare left right

  let reset () = comparisons := 0
  let count () = !comparisons
end

module Int_map = Eta_signal_map.Map.Make (Counting_order)
module Assoc = Crux.Assoc (Counting_order)

let int_map_find key map =
  match Int_map.find_opt key map with
  | Some value -> value
  | None -> invalid_arg "Eta Crux benchmark: missing map key"

type assoc_setup = {
  driver :
    Crux.Driver.t;
  endpoint : int Int_map.t Crux.Endpoint.t;
  mutable input : int Int_map.t;
  mutable output : (int * int) Int_map.t;
  child_visits : int ref;
}

let make_map size =
  match Int_map.of_list (List.init size (fun key -> (key, 0))) with
  | Ok map -> map
  | Error (`Duplicate_key _) -> assert false

type projected_value = { value : int }

type projection_population = {
  size : int;
  catalog : Crux.Projection.Catalog.t;
  description : int Crux.Endpoint.t Crux.t;
  endpoint : int Crux.Endpoint.t option ref;
  cutoff_calls : int ref;
  key_compare_calls : int ref;
}

let fixed_int_bytes value =
  let bytes = Bytes.create 8 in
  for index = 0 to 7 do
    Bytes.unsafe_set bytes index
      (Char.unsafe_chr ((value lsr (index * 8)) land 0xff))
  done;
  bytes

let projection_population size =
  let initial =
    match
      Int_map.of_list
        (List.init size (fun key -> (key, { value = 0 })))
    with
    | Ok map -> map
    | Error (`Duplicate_key _) -> assert false
  in
  let cutoff_calls = ref 0 in
  let key_compare_calls = ref 0 in
  let key_codec =
    Crux.Codec.make ~encode:(fun key -> Ok (fixed_int_bytes key))
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "projection benchmark key codec is encode-only";
          })
  in
  let value_codec =
    Crux.Codec.make
      ~encode:(fun value ->
        let bytes = Bytes.create 1 in
        Bytes.unsafe_set bytes 0 (Char.unsafe_chr value);
        Ok bytes)
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "projection benchmark value codec is encode-only";
          })
  in
  let kind =
    Crux.Projection.Kind.define ~name:"benchmark.population"
      ~key_compare:(fun left right ->
        incr key_compare_calls;
        Int.compare left right)
      ~key_codec ~value_codec ~value_equal:Int.equal
      ~cutoff:
        (Crux.Cutoff.of_equal (fun published candidate ->
             incr cutoff_calls;
             Int.equal published candidate))
  in
  let catalog =
    Crux.Projection.Catalog.create
      [ Crux.Projection.Kind.Pack kind ]
  in
  let endpoint = ref None in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:initial
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        let key = size / 2 in
        (Int_map.set key { value = action } model, None))
  in
  let model = Crux.map machine ~f:fst in
  let projections =
    Assoc.assoc ~data_cutoff:Crux.Cutoff.phys_equal model
      ~f:(fun ~key ~data ->
        Crux.Projection.publish kind ~key
          (Crux.map data ~f:(fun value -> value.value)))
    |> Crux.map ~f:ignore
  in
  let description =
    Crux.both machine projections
    |> Crux.map ~f:(fun ((_, machine_endpoint), ()) ->
           endpoint := Some machine_endpoint;
           machine_endpoint)
  in
  {
    size;
    catalog;
    description;
    endpoint;
    cutoff_calls;
    key_compare_calls;
  }

let setup_assoc runtime size =
  let child_visits = ref 0 in
  let input = make_map size in
  let config =
    Crux.State_machine.create (Crux.return ())
      ~default_model:input
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let children =
    Assoc.assoc
      ~data_cutoff:(Crux.Cutoff.of_equal Int.equal)
      (Crux.map config ~f:fst)
      ~f:(fun ~key ~data ->
        Crux.map data ~f:(fun value ->
            incr child_visits;
            (key, value)))
  in
  let driver, ((_, endpoint), output) =
    setup_identity runtime (Crux.both config children)
  in
  { driver; endpoint; input; output; child_visits }

let change_assoc runtime setup =
  let key = Int_map.cardinal setup.input / 2 in
  let previous = int_map_find key setup.input in
  Counting_order.reset ();
  let before_visits = !(setup.child_visits) in
  let changed = Int_map.set key (previous + 1) setup.input in
  send runtime setup.endpoint changed;
  let delivery = poll_delivery runtime setup.driver in
  let (_, _), output =
    opaque_delivery_value
      (Crux.Driver.Delivery.projection delivery)
    |> Option.get
  in
  answer_delivery runtime delivery;
  let comparisons = Counting_order.count () in
  let visits = !(setup.child_visits) - before_visits in
  let size = Int_map.cardinal changed in
  if comparisons > (8 * max 1 size) then
    failf "assoc comparisons %d exceed linear ceiling for %d"
      comparisons size;
  if visits <> 1 then
    failf "assoc changed-child visits: expected 1, got %d" visits;
  setup.input <- changed;
  let previous_output = setup.output in
  setup.output <- output;
  (previous_output, output)

let make_assoc_workload runtime size =
  let setup = setup_assoc runtime size in
  fun () -> ignore (change_assoc runtime setup)

let bench_eta_crux_assoc = make_assoc_workload

let make_lifecycle_overlap_workload runtime =
  let cleanup_releases = Eta.Queue.unbounded () in
  let starts = ref 0 in
  let config =
    Crux.State_machine.create (Crux.return ())
      ~default_model:(Int_map.singleton 0 ())
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let children =
    Assoc.assoc (Crux.map config ~f:fst)
      ~f:(fun ~key:_ ~data:_ ->
        Crux.lifecycle
          (Crux.return
             (Eta.Effect.acquire_release
                ~acquire:(Eta.Effect.sync (fun () -> incr starts))
                ~release:(fun () ->
                  Eta.Queue.take cleanup_releases
                  |> Eta.Effect.ignore_errors))))
  in
  let driver, ((_, endpoint), _) =
    setup_identity runtime (Crux.both config children)
  in
  register_cleanup (fun () ->
      Eta.Queue.close cleanup_releases;
      stop_driver runtime driver);
  let next_key = ref 1 in
  fun () ->
    let before = !starts in
    let replacement = Int_map.singleton !next_key () in
    incr next_key;
    send runtime endpoint replacement;
    let delivery = poll_delivery runtime driver in
    answer_delivery runtime delivery;
    ignore (run_ok runtime Eta.Effect.yield);
    if !starts <> before + 1 then
      failwith "new lifecycle did not start before old cleanup settled";
    ignore
      (run_ok runtime
         (Eta.Queue.send cleanup_releases ()
         |> Eta.Effect.ignore_errors));
    ignore (run_ok runtime Eta.Effect.yield)

type serialized_output = {
  payload : bytes;
  endpoint : unit Crux.Endpoint.t;
}

let output_codec =
  Crux.Codec.make
    ~encode:(fun output -> Ok (output.payload))
    ~decode:(fun _ ->
      Error
        {
          Crux.Codec.message =
            "benchmark output decoding is not used";
        })

let serialized_projection =
  projection ~name:"benchmark.serialized" output_codec

let output_result ~seq ~reply_to =
  Crux.Wire.Frame.Projection_result
    { seq; reply_to; result = `Accepted }
  |> Eta_crux_json.Format.encode

let output_sequence bytes =
  match Eta_crux_json.Format.decode bytes with
  | Ok (Crux.Wire.Frame.Projection_deliver { seq; _ }) -> seq
  | Ok _ | Error _ ->
      failwith "benchmark expected projection.deliver frame"

let poll_outgoing runtime peer =
  match
    run_ok runtime (Crux.Serialized_session.poll_outgoing peer)
  with
  | Some frame -> frame
  | None -> failwith "benchmark expected outgoing frame"

let acknowledge runtime peer ~seq ~reply_to =
  (match
     run_ok runtime
       (Crux.Serialized_session.receive peer
          (output_result ~seq ~reply_to))
   with
  | Ok () -> ()
  | Error _ -> failwith "benchmark projection acknowledgment failed");
  Option.iter
    (fun (stats : projection_stats) ->
      stats.deliveries <- stats.deliveries + 1)
    !active_projection_stats

let acknowledge_and_settle runtime driver peer ~seq ~reply_to =
  acknowledge runtime peer ~seq ~reply_to;
  ignore (run_ok runtime (Crux.Driver.poll driver))

let projection_counter_values (stats : projection_stats) =
  [
    ("commits", float_of_int stats.commits);
    ("deliveries", float_of_int stats.deliveries);
    ("batch_records", float_of_int stats.batch_records);
    ("encoded_entries", float_of_int stats.encoded_entries);
    ("encoded_bytes", float_of_int stats.encoded_bytes);
    ("cutoff_calls", float_of_int stats.cutoff_calls);
    ("key_compare_calls", float_of_int stats.key_compare_calls);
    ("bootstrap_entries", float_of_int stats.bootstrap_entries);
  ]

let expect_projection_counter name actual expected =
  if actual <> expected then
    failf "%s: expected %d, got %d" name expected actual

let count_projection_batch_record count _ = count + 1

let record_projection_delivery (stats : projection_stats) delivery =
  match Crux.Driver.Delivery.projection delivery with
  | Crux.Projection.Updates batch ->
      Crux.Projection.Batch.fold batch ~init:()
        ~f:(fun () (Crux.Projection.Batch.Pack _) ->
          stats.batch_records <- stats.batch_records + 1;
          stats.encoded_entries <- stats.encoded_entries + 1)
  | Crux.Projection.Bootstrap snapshot ->
      Crux.Projection.Snapshot.fold snapshot ~init:()
        ~f:(fun () (Crux.Projection.Snapshot.Pack _) ->
          stats.bootstrap_entries <- stats.bootstrap_entries + 1;
          stats.encoded_entries <- stats.encoded_entries + 1)

let finish_projection_operation
    (population : projection_population)
    (stats : projection_stats) =
  stats.cutoff_calls <- !(population.cutoff_calls);
  stats.key_compare_calls <- !(population.key_compare_calls);
  if stats.key_compare_calls > 8 * population.size then
    failf
      "key_compare_calls: %d exceeds ceiling %d for population %d"
      stats.key_compare_calls
      (8 * population.size)
      population.size;
  active_projection_stats := None

let reset_population_operation
    (population : projection_population)
    (stats : projection_stats) =
  reset_projection_stats stats;
  population.cutoff_calls := 0;
  population.key_compare_calls := 0;
  active_projection_stats := Some stats

let population_root population =
  Crux.Root.create ~catalog:population.catalog
    ~projection_capacity:population.size ~ingress_capacity:2
    ~request_capacity:1 population.description

let population_serialized_driver runtime population =
  let session, peer =
    Crux.Serialized_session.candidate
      ~max_frame_bytes:(64 * 1_024 * 1_024)
      ~format:(module Counting_format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized ~operations:[] ~session
  in
  let driver =
    Crux.Driver.create binding (population_root population)
  in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let frame = poll_outgoing runtime peer in
  let sequence = output_sequence frame in
  acknowledge_and_settle runtime driver peer ~seq:0l
    ~reply_to:sequence;
  let endpoint =
    match !(population.endpoint) with
    | Some endpoint -> endpoint
    | None ->
        failwith "projection benchmark captured no endpoint"
  in
  (driver, peer, admin, endpoint)

let population_identity_driver runtime population =
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity [])
      (population_root population)
  in
  let initial = poll_delivery runtime driver in
  let endpoint =
    match !(population.endpoint) with
    | Some endpoint -> endpoint
    | None ->
        failwith "projection benchmark captured no endpoint"
  in
  (driver, initial, endpoint)

let make_projection_identity_change_workload runtime population ~changed =
  active_projection_stats := None;
  let driver, initial, endpoint =
    population_identity_driver runtime population
  in
  answer_delivery runtime initial;
  let stats = projection_stats () in
  let next = ref 1 in
  let run () =
    reset_population_operation population stats;
    let value = if changed then !next else 0 in
    send runtime endpoint value;
    let delivery = poll_delivery runtime driver in
    stats.commits <- 1;
    record_projection_delivery stats delivery;
    stats.deliveries <- 1;
    if changed then next := 1 - !next;
    finish_projection_operation population stats;
    expect_projection_counter "commits" stats.commits 1;
    expect_projection_counter "deliveries" stats.deliveries 1;
    expect_projection_counter "batch_records" stats.batch_records
      (Bool.to_int changed);
    expect_projection_counter "encoded_entries"
      stats.encoded_entries (Bool.to_int changed);
    expect_projection_counter "encoded_bytes" stats.encoded_bytes
      0;
    expect_projection_counter "cutoff_calls" stats.cutoff_calls 1;
    expect_projection_counter "bootstrap_entries"
      stats.bootstrap_entries 0;
    answer_delivery runtime delivery
  in
  (run, fun () -> projection_counter_values stats)

let make_projection_serialized_change_workload runtime population =
  active_projection_stats := None;
  let driver, peer, _admin, endpoint =
    population_serialized_driver runtime population
  in
  let stats = projection_stats () in
  let next = ref 1 in
  let incoming_sequence = ref 1l in
  let run () =
    reset_population_operation population stats;
    let value = !next in
    send runtime endpoint value;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    stats.commits <- 1;
    let frame = poll_outgoing runtime peer in
    let sequence = output_sequence frame in
    stats.deliveries <- 1;
    next := 1 - !next;
    finish_projection_operation population stats;
    expect_projection_counter "commits" stats.commits 1;
    expect_projection_counter "deliveries" stats.deliveries 1;
    expect_projection_counter "batch_records" stats.batch_records 1;
    expect_projection_counter "encoded_entries"
      stats.encoded_entries 1;
    expect_projection_counter "encoded_bytes" stats.encoded_bytes 9;
    expect_projection_counter "cutoff_calls" stats.cutoff_calls 1;
    expect_projection_counter "bootstrap_entries"
      stats.bootstrap_entries 0;
    acknowledge_and_settle runtime driver peer
      ~seq:!incoming_sequence ~reply_to:sequence;
    incoming_sequence := Int32.add !incoming_sequence 1l;
    ()
  in
  (run, fun () -> projection_counter_values stats)

let make_projection_attach_workload runtime population =
  let stats = projection_stats () in
  let run () =
    reset_population_operation population stats;
    let _driver, delivery, _endpoint =
      population_identity_driver runtime population
    in
    stats.commits <- 1;
    record_projection_delivery stats delivery;
    stats.deliveries <- 1;
    finish_projection_operation population stats;
    expect_projection_counter "commits" stats.commits 1;
    expect_projection_counter "deliveries" stats.deliveries 1;
    expect_projection_counter "batch_records" stats.batch_records
      population.size;
    expect_projection_counter "encoded_entries"
      stats.encoded_entries population.size;
    expect_projection_counter "encoded_bytes" stats.encoded_bytes
      0;
    expect_projection_counter "cutoff_calls" stats.cutoff_calls 0;
    expect_projection_counter "bootstrap_entries"
      stats.bootstrap_entries 0;
    answer_delivery runtime delivery
  in
  (run, fun () -> projection_counter_values stats)

let make_projection_bootstrap_workload runtime population =
  active_projection_stats := None;
  let driver, _peer, admin, _endpoint =
    population_serialized_driver runtime population
  in
  let stats = projection_stats () in
  let run () =
    reset_population_operation population stats;
    let candidate, peer =
      Crux.Serialized_session.candidate
        ~max_frame_bytes:(64 * 1_024 * 1_024)
        ~format:(module Counting_format)
    in
    let replacement =
      Crux.Serialized_session.replace admin candidate
      |> Eta.Effect.or_die (function
           | Crux.Serialized_session.Starting ->
               Failure "projection bootstrap started too early"
           | Replacement_pending ->
               Failure "projection bootstrap replacement overlapped"
           | Awaiting_delivery ->
               Failure "projection bootstrap crossed a delivery"
           | Terminating ->
               Failure "projection bootstrap crossed termination"
           | Closed ->
               Failure "projection bootstrap driver closed")
      |> Eta.Effect.map (fun outcome ->
             if outcome <> Crux.Serialized_session.Replaced then
               failwith
                 "projection bootstrap replacement did not complete")
    in
    let remote =
      let open Eta.Syntax in
      let* frame =
        Crux.Serialized_session.await_outgoing peer
        |> Eta.Effect.or_die (function
             | Crux.Serialized_session.Session_closed ->
                 Failure "projection bootstrap session closed"
             | Protocol_error _ ->
                 Failure "projection bootstrap protocol failed")
      in
      let sequence = output_sequence frame in
      stats.deliveries <- 1;
      finish_projection_operation population stats;
      expect_projection_counter "commits" stats.commits 0;
      expect_projection_counter "deliveries" stats.deliveries 1;
      expect_projection_counter "batch_records" stats.batch_records 0;
      expect_projection_counter "encoded_entries"
        stats.encoded_entries population.size;
      expect_projection_counter "encoded_bytes" stats.encoded_bytes
        (9 * population.size);
      expect_projection_counter "cutoff_calls" stats.cutoff_calls 0;
      expect_projection_counter "bootstrap_entries"
        stats.bootstrap_entries population.size;
      let* received =
        Crux.Serialized_session.receive peer
          (output_result ~seq:0l ~reply_to:sequence)
      in
      (match received with
      | Ok () -> ()
      | Error _ ->
          failwith "projection bootstrap acknowledgment failed");
      let+ _ = Crux.Driver.poll driver in
      ()
    in
    ignore (run_ok runtime (Eta.Effect.par replacement remote))
  in
  (run, fun () -> projection_counter_values stats)

let make_projection_absent_workload runtime =
  let endpoint = ref None in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action:() ->
        (model + 1, None))
  in
  let description =
    Crux.cutoff machine ~cutoff:Crux.Cutoff.always
    |> Crux.map ~f:(fun (_, machine_endpoint) ->
        endpoint := Some machine_endpoint)
  in
  let root =
    Crux.Root.create
      ~catalog:(Crux.Projection.Catalog.create [])
      ~projection_capacity:1 ~ingress_capacity:2
      ~request_capacity:1 description
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let initial = poll_delivery runtime driver in
  answer_delivery runtime initial;
  let endpoint =
    match !endpoint with
    | Some endpoint -> endpoint
    | None -> failwith "projection absent benchmark captured no endpoint"
  in
  let observation : projection_absent_observation =
    {
      commits = 0;
      deliveries = 0;
      batch_records = 0;
      encoded_entries = 0;
      encoded_bytes = 0;
      cutoff_calls = 0;
      bootstrap_entries = 0;
    }
  in
  let run () =
    send runtime endpoint ();
    let delivery = poll_delivery runtime driver in
    let batch_records =
      match Crux.Driver.Delivery.projection delivery with
      | Crux.Projection.Updates batch ->
          Crux.Projection.Batch.fold batch ~init:0
            ~f:count_projection_batch_record
      | Bootstrap _ ->
          failwith "projection absent benchmark received bootstrap"
    in
    if batch_records <> 0 then
      failwith "projection absent emitted batch records";
    observation.commits <- 1;
    observation.deliveries <- 1;
    observation.batch_records <- batch_records;
    observation.encoded_entries <- 0;
    observation.encoded_bytes <- 0;
    observation.cutoff_calls <- 0;
    observation.bootstrap_entries <- 0;
    if
      observation.commits <> 1 || observation.deliveries <> 1
      || observation.batch_records <> 0
      || observation.encoded_entries <> 0
      || observation.encoded_bytes <> 0
      || observation.cutoff_calls <> 0
      || observation.bootstrap_entries <> 0
    then failwith "projection absent counter mismatch";
    answer_delivery runtime delivery
  in
  ( run,
    fun () ->
      let observed = observation in
      [
        ("commits", float_of_int observed.commits);
        ("deliveries", float_of_int observed.deliveries);
        ("batch_records", float_of_int observed.batch_records);
        ("encoded_entries", float_of_int observed.encoded_entries);
        ("encoded_bytes", float_of_int observed.encoded_bytes);
        ("cutoff_calls", float_of_int observed.cutoff_calls);
        ("key_compare_calls", 0.);
        ("bootstrap_entries", float_of_int observed.bootstrap_entries);
      ] )

let make_serialized_workload runtime payload_size =
  let session, peer =
    Crux.Serialized_session.candidate
      ~max_frame_bytes:16_384
      ~format:(module Counting_format)
  in
  let binding, _ =
    Crux.Driver.Binding.serialized
      ~operations:[] ~session
  in
  let payload = Bytes.make payload_size 'x' in
  let endpoint_ref = ref None in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action:() ->
        (model + 1, None))
  in
  let description =
    Crux.map machine ~f:(fun (_, endpoint) ->
        endpoint_ref := Some endpoint;
        { payload; endpoint })
  in
  let root =
    projection_root serialized_projection ~ingress_capacity:2
      ~request_capacity:1 description
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let first = poll_outgoing runtime peer in
  let first_sequence = output_sequence first in
  acknowledge runtime peer ~seq:0l ~reply_to:first_sequence;
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let endpoint =
    match !endpoint_ref with
    | Some endpoint -> endpoint
    | None ->
        failwith "serialized benchmark endpoint was not captured"
  in
  let incoming_sequence = ref 1l in
  fun () ->
    let wire_before = !wire_operations in
    send runtime endpoint ();
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let frame = poll_outgoing runtime peer in
    let reply_to = output_sequence frame in
    acknowledge runtime peer ~seq:!incoming_sequence ~reply_to;
    incoming_sequence := Int32.add !incoming_sequence 1l;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let wire_count = !wire_operations - wire_before in
    if wire_count <> 2 then
      failf "serialized driver performed %d wire operations"
        wire_count

let make_identity_driver_workload runtime =
  let run = make_action_workload runtime in
  fun () ->
    let wire_before = !wire_operations in
    run ();
    let wire_count = !wire_operations - wire_before in
    if wire_count <> 0 then
      failf "identity driver performed %d wire operations"
        wire_count

let make_capacity_workload runtime capacity =
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let codec =
    Crux.Codec.make
      ~encode:(fun value -> Ok (Bytes.of_string (string_of_int value)))
      ~decode:(fun bytes ->
        try Ok (int_of_string (Bytes.to_string bytes))
        with Failure message ->
          Error { Crux.Codec.message = message })
  in
  let exported =
    Crux.Exported_endpoint.create (Crux.map machine ~f:snd)
      ~codec
  in
  let root =
    opaque_root ~ingress_capacity:capacity ~request_capacity:1 exported
  in
  let export, post_commit =
    match run_ok runtime (Crux.Root.advance root) with
    | Ok (Crux.Root.Committed { commit; post_commit }) ->
        (opaque_commit_value commit |> Option.get, post_commit)
    | _ -> failwith "capacity benchmark failed to start"
  in
  ignore
    (run_ok runtime
       (Crux.Post_commit.start post_commit
       |> Eta.Effect.ignore_errors));
  let attempts = capacity + max 1 (capacity / 4) in
  fun () ->
    let admitted = ref 0 in
    for value = 1 to attempts do
      match Crux.Exported_endpoint.try_invoke export value with
      | Ok (Ok (Ok ())) -> incr admitted
      | Ok (Error Crux.Exported_endpoint.Full) -> ()
      | Ok (Ok (Error Crux.Endpoint.Ingress_closed))
      | Error _ ->
          failwith "capacity benchmark export closed"
    done;
    if !admitted <> capacity then
      failf "capacity %d admitted %d entries" capacity !admitted;
    for _ = 1 to capacity do
      match run_ok runtime (Crux.Root.advance root) with
      | Ok (Crux.Root.Committed { post_commit; _ }) ->
          ignore
            (run_ok runtime
               (Crux.Post_commit.start post_commit
               |> Eta.Effect.ignore_errors))
      | _ -> failwith "capacity benchmark failed to drain"
    done

let make_request_capacity_workload runtime capacity =
  let operation =
    Crux.Host_operation.define ~name:"bench.capacity"
      ~request:
        (Crux.Codec.make ~encode:(fun bytes -> Ok (Bytes.of_string bytes))
           ~decode:(fun bytes -> Ok (Bytes.to_string bytes)))
      ~response:
        (Crux.Codec.make ~encode:(fun bytes -> Ok (Bytes.of_string bytes))
           ~decode:(fun bytes -> Ok (Bytes.to_string bytes)))
  in
  let binding =
    Crux.Driver.Binding.identity
      [ Crux.Host_operation.Pack operation ]
  in
  let root =
    opaque_root ~ingress_capacity:1 ~request_capacity:capacity
      (Crux.return ())
  in
  let driver = Crux.Driver.create binding root in
  let initial = poll_delivery runtime driver in
  answer_delivery runtime initial;
  register_cleanup (fun () -> stop_driver runtime driver);
  let requester =
    Crux.Driver.Binding.requester binding operation
  in
  let completed = ref 0 in
  let launch =
    List.init (capacity + 1) (fun index ->
        Crux.Requester.request requester (string_of_int index)
        |> Eta.Effect.to_result
        |> Eta.Effect.map (fun _ -> incr completed)
        |> Eta.Spi.daemon)
    |> Eta.Effect.concat
  in
  let resolve event =
    let open Eta.Syntax in
    let* handled =
      Crux.Request.Driver_event.handle event operation
        ~f:(fun request ~resolve ~on_cancel:_ ->
          let+ _ = resolve request in
          ())
    in
    let* completion =
      Crux.Request.Driver_event.accepted event
    in
    match handled, completion with
    | Crux.Request.Driver_event.Handled, Ok () ->
        Eta.Effect.unit
    | Crux.Request.Driver_event.Different_operation, _
    | Crux.Request.Driver_event.Already_handled, _
    | Crux.Request.Driver_event.Closed _, _
    | _, Error Crux.Request.Driver_event.Already_completed ->
        Eta.Effect.die_message
          "request-capacity benchmark completed an event incorrectly"
  in
  let rec collect count events attempts =
    if count = capacity then List.rev events
    else if attempts = 0 then
      failwith
        "request-capacity benchmark did not reach saturation"
    else
      match run_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Request event) ->
          collect (count + 1) (event :: events) attempts
      | Some _ | None ->
          ignore (run_ok runtime Eta.Effect.yield);
          collect count events (attempts - 1)
  in
  let rec await_request attempts =
    if attempts = 0 then
      failwith
        "request-capacity benchmark did not reuse a permit"
    else
      match run_ok runtime (Crux.Driver.poll driver) with
      | Some (Crux.Driver.Request event) -> event
      | Some _ | None ->
          ignore (run_ok runtime Eta.Effect.yield);
          await_request (attempts - 1)
  in
  let rec await_completions expected attempts =
    if !completed = expected then ()
    else if attempts = 0 then
      failwith
        "request-capacity benchmark stranded a requester"
    else (
      ignore (run_ok runtime Eta.Effect.yield);
      await_completions expected (attempts - 1))
  in
  fun () ->
    completed := 0;
    ignore (run_ok runtime launch);
    let admitted = collect 0 [] 10_000 in
    (match run_ok runtime (Crux.Driver.poll driver) with
    | None -> ()
    | Some _ ->
        failf "request capacity %d admitted too many requests"
          capacity);
    let first, rest =
      match admitted with
      | first :: rest -> (first, rest)
      | [] -> assert false
    in
    ignore (run_ok runtime (resolve first));
    let last = await_request 10_000 in
    List.iter
      (fun event -> ignore (run_ok runtime (resolve event)))
      (rest @ [ last ]);
    await_completions (capacity + 1) 10_000;
    ignore (run_ok runtime Eta.Effect.yield)

let make_serialized_handle_retention_workload runtime =
  let selector =
    Crux.State_machine.create (Crux.return ())
      ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let child =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let export =
    Crux.Exported_endpoint.create (Crux.map child ~f:snd)
      ~codec:
        (Crux.Codec.make
           ~encode:(fun value ->
             Ok (Bytes.of_string (string_of_int value)))
           ~decode:(fun bytes ->
             match
               int_of_string_opt (Bytes.to_string bytes)
             with
             | Some value -> Ok value
             | None ->
                 Error
                   {
                     Crux.Codec.message =
                       "expected an integer";
                   }))
  in
  let selected =
    Crux.bind (Crux.map selector ~f:fst) ~f:(fun active ->
        if active then Crux.map export ~f:Option.some
        else Crux.return None)
  in
  let description = Crux.both selector selected in
  let selector_endpoint = ref None in
  let observed_export = Weak.create 1 in
  let codec =
    Crux.Codec.make
      ~encode:(fun ((_, endpoint), export) ->
        selector_endpoint := Some endpoint;
        match export with
        | None -> Ok Bytes.empty
        | Some export ->
            Weak.set observed_export 0 (Some export);
            Ok (Crux.Exported_endpoint.remote_handle export))
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "handle-retention output is encode-only";
          })
  in
  let handle_projection =
    projection ~name:"benchmark.handle-retention" codec
  in
  let candidate, initial_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:2_048
      ~format:(module Counting_format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized
      ~operations:[] ~session:candidate
  in
  let root =
    projection_root handle_projection ~ingress_capacity:1
      ~request_capacity:1 description
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let first = poll_outgoing runtime initial_peer in
  let first_sequence = output_sequence first in
  let first_handle =
    match Eta_crux_json.Format.decode first with
    | Ok (Crux.Wire.Frame.Projection_deliver { content; _ })
      when
        let output = projection_content_value content in
        Bytes.length output > 0 ->
        projection_content_value content
    | Ok _ | Error _ ->
        failwith
          "handle-retention benchmark emitted no initial handle"
  in
  acknowledge runtime initial_peer ~seq:0l
    ~reply_to:first_sequence;
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let selector_endpoint =
    match !selector_endpoint with
    | Some endpoint -> endpoint
    | None ->
        failwith
          "handle-retention benchmark captured no selector endpoint"
  in
  let peer = ref initial_peer in
  let incoming_sequence = ref 1l in
  let previous_handle = ref first_handle in
  let output_frame peer =
    let bytes = poll_outgoing runtime peer in
    match Eta_crux_json.Format.decode bytes with
    | Ok
        (Crux.Wire.Frame.Projection_deliver
          { seq; content; _ }) ->
        (seq, projection_content_value content)
    | Ok _ | Error _ ->
        failwith
          "handle-retention benchmark expected projection delivery"
  in
  register_cleanup (fun () -> stop_driver runtime driver);
  fun () ->
    send runtime selector_endpoint false;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let remove_sequence, removed_output =
      output_frame !peer
    in
    if Bytes.length removed_output <> 0 then
      failwith
        "removed export remained in serialized projection";
    acknowledge runtime !peer ~seq:!incoming_sequence
      ~reply_to:remove_sequence;
    incoming_sequence :=
      Int32.add !incoming_sequence 1l;
    ignore (run_ok runtime (Crux.Driver.poll driver));

    let candidate, replacement_peer =
      Crux.Serialized_session.candidate
        ~max_frame_bytes:2_048
        ~format:(module Counting_format)
    in
    let replacement =
      Crux.Serialized_session.replace admin candidate
      |> Eta.Effect.or_die (function
           | Crux.Serialized_session.Starting ->
               Failure "handle-retention replacement started too early"
           | Replacement_pending ->
               Failure "handle-retention replacement overlapped"
           | Awaiting_delivery ->
               Failure "handle-retention replacement crossed a delivery"
           | Terminating ->
               Failure "handle-retention replacement crossed termination"
           | Closed ->
               Failure "handle-retention driver closed")
    in
    let remote =
      let open Eta.Syntax in
      let* bytes =
        Crux.Serialized_session.await_outgoing
          replacement_peer
        |> Eta.Effect.or_die (function
             | Crux.Serialized_session.Session_closed ->
                 Failure "handle-retention replacement session closed"
             | Protocol_error _ ->
                 Failure "handle-retention replacement protocol failed")
      in
      let sequence, output =
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Projection_deliver
              {
                seq;
                reason = `Session_replacement;
                content;
              }) ->
            (seq, projection_content_value content)
        | Ok _ | Error _ ->
            failwith
              "handle-retention replacement projection malformed"
      in
      if Bytes.length output <> 0 then
        failwith
          "replacement retained a removed export";
      let* received =
        Crux.Serialized_session.receive replacement_peer
          (output_result ~seq:0l ~reply_to:sequence)
      in
      (match received with
      | Ok () -> ()
      | Error _ ->
          failwith
            "handle-retention replacement acknowledgment failed");
      let+ _ = Crux.Driver.poll driver in
      ()
    in
    let outcome, () =
      run_ok runtime (Eta.Effect.par replacement remote)
    in
    if outcome <> Crux.Serialized_session.Replaced then
      failwith "handle-retention replacement did not complete";
    peer := replacement_peer;
    incoming_sequence := 1l;

    let invocation =
      Crux.Wire.Frame.Endpoint_invoke
        {
          seq = !incoming_sequence;
          handle = !previous_handle;
          payload = Bytes.of_string "1";
        }
      |> Eta_crux_json.Format.encode
    in
    (match
       run_ok runtime
         (Crux.Serialized_session.receive !peer invocation)
     with
    | Ok () -> ()
    | Error _ ->
        failwith
          "handle-retention stale invocation closed the session");
    incoming_sequence :=
      Int32.add !incoming_sequence 1l;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let stale =
      match
        poll_outgoing runtime !peer
        |> Eta_crux_json.Format.decode
      with
      | Ok
          (Crux.Wire.Frame.Endpoint_result
            { result = `Stale_handle; _ }) ->
          true
      | Ok _ | Error _ -> false
    in
    if not stale then
      failwith
        "old-session handle survived replacement";
    Gc.full_major ();
    if Weak.check observed_export 0 then
      failwith
        "removed export survived replacement and major collection";

    send runtime selector_endpoint true;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    let add_sequence, fresh_handle =
      output_frame !peer
    in
    if
      Bytes.length fresh_handle = 0
      || Bytes.equal fresh_handle !previous_handle
    then
      failwith
        "reentered export did not receive a fresh handle";
    acknowledge runtime !peer ~seq:!incoming_sequence
      ~reply_to:add_sequence;
    incoming_sequence :=
      Int32.add !incoming_sequence 1l;
    ignore (run_ok runtime (Crux.Driver.poll driver));
    previous_handle := fresh_handle


let make_telemetry_workload runtime ~suppressed =
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, None))
  in
  let driver, (_, endpoint) = setup_identity runtime machine in
  let open Eta.Syntax in
  let operation =
    let* () =
      Crux.Endpoint.send endpoint 1
      |> Eta.Effect.or_die (function
           | Crux.Endpoint.Ingress_closed ->
               Failure "telemetry benchmark ingress closed")
    in
    let* event = Crux.Driver.poll driver in
    let delivery =
      match event with
      | Some (Crux.Driver.Deliver delivery) -> delivery
      | Some _ | None ->
          failwith "telemetry benchmark expected delivery"
    in
    let+ completion = Crux.Driver.Delivery.delivered delivery in
    match completion with
    | Ok () -> ()
    | Error Crux.Driver.Delivery.Already_completed ->
        failwith "telemetry benchmark delivery completed twice"
  in
  let operation =
    if suppressed then
      Eta_observability.suppress_observability operation
    else operation
  in
  fun () -> run_ok runtime operation

let deterministic_counters = Hashtbl.create 32
let dynamic_counters = Hashtbl.create 16

let workload ?(counters = []) name run =
  let name = "eta_crux." ^ name in
  Hashtbl.replace deterministic_counters name counters;
  Bench_lib.workload (name) run

let mean values =
  Array.fold_left ( +. ) 0. values
  /. float_of_int (Array.length values)

let stddev values =
  if Array.length values < 2 then 0.
  else
    let average = mean values in
    Array.fold_left
      (fun total value ->
        let difference = value -. average in
        total +. (difference *. difference))
      0. values
    /. float_of_int (Array.length values - 1)
    |> sqrt

let percentile values fraction =
  let sorted = Array.copy values in
  Array.sort Float.compare sorted;
  let index =
    int_of_float
      (ceil
         ((float_of_int (Array.length sorted) *. fraction)
         -. 1.))
    |> max 0 |> min (Array.length sorted - 1)
  in
  sorted.(index)

let json_float value =
  if
    classify_float value = FP_nan
    || classify_float value = FP_infinite
  then "0"
  else Printf.sprintf "%.6f" value

let emit_samples ~name ~metric ~unit_ ~operations values =
  let samples =
    values |> Array.to_list |> List.map json_float
    |> String.concat ","
  in
  Printf.printf
    "{\"name\":\"%s\",\"metric\":\"%s\",\"unit\":\"%s\",\"operations_per_sample\":%d,\"samples\":[%s],\"mean\":%s,\"stddev\":%s,\"median\":%s,\"p95\":%s,\"min\":%s,\"max\":%s}\n%!"
    name metric unit_ operations samples
    (json_float (mean values))
    (json_float (stddev values))
    (json_float (percentile values 0.5))
    (json_float (percentile values 0.95))
    (json_float (Array.fold_left min infinity values))
    (json_float (Array.fold_left max neg_infinity values))

let elapsed operations run =
  let started = Unix.gettimeofday () in
  Bench_lib.repeat operations run;
  Unix.gettimeofday () -. started

let rec calibrate ~minimum_seconds run operations =
  if minimum_seconds = 0. then operations
  else
    let seconds = elapsed operations run in
    if seconds >= minimum_seconds then operations
    else calibrate ~minimum_seconds run (operations * 2)

let operation_groups = Hashtbl.create 1

let operation_group = function
  | "eta_crux.telemetry.disabled"
  | "eta_crux.telemetry.absent_control" ->
      Some "eta_crux.telemetry"
  | _ -> None

let measure_workload options
    (workload : Bench_lib.workload) =
  let sample_count =
    if options.Bench_lib.quick then options.samples
    else if options.samples = 5 then 31
    else options.samples
  in
  let warmups = if options.quick then 0 else 5 in
  let minimum_seconds = if options.quick then 0. else 0.05 in
  let operations =
    match operation_group workload.name with
    | Some group -> (
        match Hashtbl.find_opt operation_groups group with
        | Some operations -> operations
        | None ->
            let operations =
              calibrate ~minimum_seconds
                workload.Bench_lib.run 1
            in
            Hashtbl.add operation_groups group operations;
            operations)
    | None ->
        calibrate ~minimum_seconds workload.Bench_lib.run 1
  in
  for _ = 1 to warmups do
    Bench_lib.repeat operations workload.run
  done;
  let walls = Array.make sample_count 0. in
  let allocated = Array.make sample_count 0. in
  let minors = Array.make sample_count 0. in
  let promoted = Array.make sample_count 0. in
  let majors = Array.make sample_count 0. in
  let operation_count = float_of_int operations in
  for sample = 0 to sample_count - 1 do
    Gc.compact ();
    let before_minor, before_promoted, before_major =
      Gc.counters ()
    in
    let started = Unix.gettimeofday () in
    Bench_lib.repeat operations workload.run;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major =
      Gc.counters ()
    in
    walls.(sample) <-
      ((stopped -. started) *. 1_000_000_000.)
      /. operation_count;
    minors.(sample) <-
      (after_minor -. before_minor) /. operation_count;
    promoted.(sample) <-
      (after_promoted -. before_promoted)
      /. operation_count;
    majors.(sample) <-
      (after_major -. before_major) /. operation_count;
    allocated.(sample) <-
      minors.(sample) +. majors.(sample)
      -. promoted.(sample)
  done;
  let emit metric unit_ values =
    emit_samples ~name:workload.name ~metric ~unit_
      ~operations values
  in
  emit "wall_ns" "ns" walls;
  emit "allocated_words" "words" allocated;
  emit "minor_words" "words" minors;
  emit "promoted_words" "words" promoted;
  emit "major_words" "words" majors;
  Option.iter
    (fun counters ->
      Hashtbl.replace deterministic_counters workload.name
        (counters ()))
    (Hashtbl.find_opt dynamic_counters workload.name);
  Hashtbl.find_opt deterministic_counters workload.name
  |> Option.value ~default:[]
  |> List.iter (fun (counter, value) ->
         emit ("counter." ^ counter) "{event}/op"
           (Array.make sample_count value))

let run_benchmarks options workloads =
  List.iter (measure_workload options) workloads

let () =
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch
      ~clock:(Eio.Stdenv.clock environment) ()
  in
  let options = Bench_lib.parse_args () in
  let selected ?counters name make =
    let full_name = "eta_crux." ^ name in
    if Bench_lib.should_run options full_name then
      [ workload ?counters name (make ()) ]
    else []
  in
  let selected_dynamic name make =
    let full_name = "eta_crux." ^ name in
    if Bench_lib.should_run options full_name then
      let run, counters = make () in
      Hashtbl.replace dynamic_counters full_name counters;
      [ workload name run ]
    else []
  in
  let population_10_000 =
    lazy (projection_population 10_000)
  in
  let population_100_000 =
    lazy (projection_population 100_000)
  in
  let workloads =
    selected
      ~counters:[ ("commits", 1.); ("deliveries", 1.) ]
      "action.complete_advancement"
      (fun () -> make_action_workload runtime)
    @ selected_dynamic "projection.absent"
        (fun () -> make_projection_absent_workload runtime)
    @ selected
        ~counters:
          [ ("commits", 1.); ("dependent_projections", 0.) ]
        "incremental.equal_model"
        (fun () -> make_unchanged_workload runtime)
    @ selected
        ~counters:[ ("child_visits", 1.) ]
        "assoc.changed_child.10000"
        (fun () -> bench_eta_crux_assoc runtime 10_000)
    @ selected
        ~counters:[ ("child_visits", 1.) ]
        "assoc.changed_child.100000"
        (fun () -> bench_eta_crux_assoc runtime 100_000)
    @ selected_dynamic "projection.no_change.10000"
        (fun () ->
          make_projection_identity_change_workload runtime
            (Lazy.force population_10_000) ~changed:false)
    @ selected_dynamic "projection.no_change.100000"
        (fun () ->
          make_projection_identity_change_workload runtime
            (Lazy.force population_100_000) ~changed:false)
    @ selected_dynamic "projection.one_changed.10000"
        (fun () ->
          make_projection_serialized_change_workload runtime
            (Lazy.force population_10_000))
    @ selected_dynamic "projection.one_changed.100000"
        (fun () ->
          make_projection_serialized_change_workload runtime
            (Lazy.force population_100_000))
    @ selected_dynamic "projection.identity.one_changed.10000"
        (fun () ->
          make_projection_identity_change_workload runtime
            (Lazy.force population_10_000) ~changed:true)
    @ selected_dynamic "projection.identity.one_changed.100000"
        (fun () ->
          make_projection_identity_change_workload runtime
            (Lazy.force population_100_000) ~changed:true)
    @ selected_dynamic "projection.attach.10000"
        (fun () ->
          make_projection_attach_workload runtime
            (Lazy.force population_10_000))
    @ selected_dynamic "projection.attach.100000"
        (fun () ->
          make_projection_attach_workload runtime
            (Lazy.force population_100_000))
    @ selected_dynamic "projection.bootstrap.10000"
        (fun () ->
          make_projection_bootstrap_workload runtime
            (Lazy.force population_10_000))
    @ selected_dynamic "projection.bootstrap.100000"
        (fun () ->
          make_projection_bootstrap_workload runtime
            (Lazy.force population_100_000))
    @ selected
        ~counters:
          [ ("new_starts", 1.); ("cleanup_releases", 1.) ]
        "lifecycle.overlapping_cleanup"
        (fun () -> make_lifecycle_overlap_workload runtime)
    @ selected ~counters:[ ("wire_operations", 0.) ]
        "driver.identity"
        (fun () -> make_identity_driver_workload runtime)
    @ selected
        ~counters:
          [ ("wire_operations", 2.); ("payload_bytes", 0.) ]
        "driver.serialized.0b"
        (fun () -> make_serialized_workload runtime 0)
    @ selected
        ~counters:
          [ ("wire_operations", 2.); ("payload_bytes", 64.) ]
        "driver.serialized.64b"
        (fun () -> make_serialized_workload runtime 64)
    @ selected
        ~counters:
          [ ("wire_operations", 2.); ("payload_bytes", 4_096.) ]
        "driver.serialized.4096b"
        (fun () -> make_serialized_workload runtime 4_096)
    @ selected ~counters:[ ("commits", 1.) ]
        "telemetry.disabled"
        (fun () ->
          make_telemetry_workload runtime ~suppressed:true)
    @ selected ~counters:[ ("commits", 1.) ]
        "telemetry.absent_control"
        (fun () ->
          make_telemetry_workload runtime ~suppressed:false)
    @ selected ~counters:[ ("commits", 1.) ]
        "observer.disabled"
        (fun () -> make_action_workload runtime)
    @ selected ~counters:[ ("commits", 1.) ]
        "reset.disabled"
        (fun () -> make_action_workload runtime)
    @ selected ~counters:[ ("commits", 1.) ]
        "poll.disabled"
        (fun () -> make_action_workload runtime)
    @ selected
        ~counters:
          [ ("max_pending", 1.); ("admissions", 1.) ]
        "capacity.ingress.1"
        (fun () -> make_capacity_workload runtime 1)
    @ selected
        ~counters:
          [ ("max_pending", 64.); ("admissions", 64.) ]
        "capacity.ingress.64"
        (fun () -> make_capacity_workload runtime 64)
    @ selected
        ~counters:
          [ ("max_pending", 1_024.); ("admissions", 1_024.) ]
        "capacity.ingress.1024"
        (fun () -> make_capacity_workload runtime 1_024)
    @ selected
        ~counters:
          [ ("max_pending", 1.); ("completions", 2.) ]
        "capacity.request.1"
        (fun () -> make_request_capacity_workload runtime 1)
    @ selected
        ~counters:
          [ ("max_pending", 64.); ("completions", 65.) ]
        "capacity.request.64"
        (fun () -> make_request_capacity_workload runtime 64)
    @ selected
        ~counters:
          [ ("max_pending", 1_024.); ("completions", 1_025.) ]
        "capacity.request.1024"
        (fun () -> make_request_capacity_workload runtime 1_024)
  in
  run_benchmarks options workloads;
  List.iter (fun cleanup -> cleanup ()) !cleanup_actions
