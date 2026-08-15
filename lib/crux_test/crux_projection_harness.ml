module Crux = Eta_crux

type ('key, 'value) keyed = {
  name : string;
  kind : ('key, 'value) Crux.Projection.Kind.t;
  catalog : Crux.Projection.Catalog.t;
  key_compare : 'key -> 'key -> int;
  key_codec : 'key Crux.Codec.t;
  value_codec : 'value Crux.Codec.t;
}

type 'value t = (unit, 'value) keyed

let unit_codec =
  Crux.Codec.make
    ~encode:(fun () -> Ok Bytes.empty)
    ~decode:(fun bytes ->
      if Bytes.length bytes = 0 then Ok ()
      else Error { Crux.Codec.message = "expected an empty unit key" })

let keyed ~name ~key_compare ~key_codec ~value_codec ~value_equal ~cutoff =
  let kind =
    Crux.Projection.Kind.define ~name ~key_compare
      ~key_codec ~value_codec ~value_equal ~cutoff
  in
  let catalog =
    Crux.Projection.Catalog.create
      [ Crux.Projection.Kind.Pack kind ]
  in
  { name; kind; catalog; key_compare; key_codec; value_codec }

let create ~name ~codec ~value_equal ~cutoff =
  keyed ~name ~key_compare:Unit.compare ~key_codec:unit_codec
    ~value_codec:codec ~value_equal ~cutoff

let publish harness description =
  Crux.Projection.publish harness.kind ~key:() description

let root ?post_commit_effect_observer harness ~projection_capacity
    ~ingress_capacity ~request_capacity description =
  Crux.Root.create ?post_commit_effect_observer
    ~catalog:harness.catalog ~projection_capacity ~ingress_capacity
    ~request_capacity (publish harness description)

let seed_incarnation_counter root next =
  Eta_crux__Crux_projection_barrier.seed_incarnation_counter
    (Obj.repr root) next

let snapshot_value harness snapshot =
  match Crux.Projection.Snapshot.find_opt harness.kind ~key:() snapshot with
  | None -> None
  | Some entry -> Some entry.value

let commit_value harness commit =
  snapshot_value harness (Crux.Projection.Commit.snapshot commit)

let delivery_value harness = function
  | Crux.Projection.Bootstrap snapshot ->
      snapshot_value harness snapshot
  | Updates batch ->
      let updates =
        Crux.Projection.Batch.find_opt harness.kind ~key:() batch
      in
      let rec latest = function
        | [] -> None
        | Crux.Projection.Attached entry :: rest
        | Changed entry :: rest -> (
            match latest rest with
            | Some _ as value -> value
            | None -> Some entry.value)
        | Removed _ :: rest -> latest rest
      in
      latest updates

module Keyed = struct
  type ('key, 'value) t = ('key, 'value) keyed

  let create = keyed
  let catalog harness = harness.catalog

  let publish harness ~key description =
    Crux.Projection.publish harness.kind ~key description

  let snapshot_find_opt harness ~key snapshot =
    Crux.Projection.Snapshot.find_opt harness.kind ~key snapshot

  let batch_find_opt harness ~key batch =
    Crux.Projection.Batch.find_opt harness.kind ~key batch
end

module Wire_recipient = struct
  type rejection =
    | Unknown_kind
    | Invalid_key
    | Noncanonical_key
    | Zero_incarnation
    | Noncanonical_order
    | Duplicate_identity
    | Invalid_transition
    | Codec_error
    | Capacity_exceeded
    | Install_failed

  type ('key, 'value) stored = {
    key : 'key;
    incarnation : int64;
    value : 'value;
  }

  type ('key, 'value) t = {
    harness : ('key, 'value) keyed;
    capacity : int;
    mutable delivered : ('key, 'value) stored list;
    mutable installed : bool;
    mutable fail_next_install : bool;
  }

  type ('key, 'value) decoded_update =
    | Attached of ('key, 'value) stored
    | Changed of ('key, 'value) stored
    | Removed of {
        key : 'key;
        incarnation : int64;
      }

  let create harness ~capacity =
    if capacity <= 0 then
      invalid_arg
        "Eta_crux_test.Projection_harness.Wire_recipient.create: capacity must be positive";
    {
      harness;
      capacity;
      delivered = [];
      installed = false;
      fail_next_install = false;
    }

  let fail_next_install recipient =
    recipient.fail_next_install <- true

  let installed recipient = recipient.installed
  let delivered_count recipient = List.length recipient.delivered

  let find_value recipient ~key =
    recipient.delivered
    |> List.find_map (fun stored ->
           if recipient.harness.key_compare key stored.key = 0 then
             Some stored.value
           else None)

  let find_incarnation recipient ~key =
    recipient.delivered
    |> List.find_map (fun stored ->
           if recipient.harness.key_compare key stored.key = 0 then
             Some stored.incarnation
           else None)

  let decode_key harness bytes =
    match Crux.Codec.decode harness.key_codec bytes with
    | Error _ -> Error Invalid_key
    | Ok key -> (
        match Crux.Codec.encode harness.key_codec key with
        | Error _ -> Error Codec_error
        | Ok canonical ->
            if Bytes.equal canonical bytes then Ok key
            else Error Noncanonical_key)

  let decode_value harness bytes =
    match Crux.Codec.decode harness.value_codec bytes with
    | Ok value -> Ok value
    | Error _ -> Error Codec_error

  let ( let* ) result f =
    match result with
    | Ok value -> f value
    | Error _ as error -> error

  let decode_identity harness ~kind ~key ~incarnation =
    if not (String.equal kind harness.name) then Error Unknown_kind
    else if Int64.equal incarnation 0L then Error Zero_incarnation
    else
      let* key = decode_key harness key in
      Ok (key, incarnation)

  let decode_entry harness (entry : Crux.Wire.Frame.projection_entry) =
    let* key, incarnation =
      decode_identity harness ~kind:entry.kind ~key:entry.key
        ~incarnation:entry.incarnation
    in
    let* value = decode_value harness entry.value in
    Ok { key; incarnation; value }

  let decode_update harness = function
    | Crux.Wire.Frame.Attached entry ->
        let* entry = decode_entry harness entry in
        Ok (Attached entry)
    | Changed entry ->
        let* entry = decode_entry harness entry in
        Ok (Changed entry)
    | Removed { kind; key; incarnation } ->
        let* key, incarnation =
          decode_identity harness ~kind ~key ~incarnation
        in
        Ok (Removed { key; incarnation })

  let update_key = function
    | Attached entry | Changed entry -> entry.key
    | Removed removed -> removed.key

  let decode_all decode values =
    let rec loop reversed = function
      | [] -> Ok (List.rev reversed)
      | value :: rest ->
          let* decoded = decode value in
          loop (decoded :: reversed) rest
    in
    loop [] values

  let canonical_entries harness entries =
    let rec loop = function
      | left :: (right :: _ as rest) ->
          let compared = harness.key_compare left.key right.key in
          if compared = 0 then Error Duplicate_identity
          else if compared > 0 then Error Noncanonical_order
          else loop rest
      | [] | [ _ ] -> Ok ()
    in
    loop entries

  let canonical_updates harness updates =
    let rec loop previous_key previous_was_removed = function
      | [] -> Ok ()
      | update :: rest ->
          let key = update_key update in
          (match previous_key with
          | None -> loop (Some key) (match update with Removed _ -> true | _ -> false) rest
          | Some previous ->
              let compared = harness.key_compare previous key in
              if compared > 0 then Error Noncanonical_order
              else if compared = 0 then
                if previous_was_removed then
                  (match update with
                  | Attached _ -> loop (Some key) false rest
                  | Changed _ | Removed _ -> Error Invalid_transition)
                else Error Invalid_transition
              else
                loop (Some key)
                  (match update with Removed _ -> true | _ -> false)
                  rest)
    in
    loop None false updates

  let find_and_remove compare key entries =
    let rec loop reversed = function
      | [] -> (None, List.rev reversed)
      | stored :: rest ->
          let compared = compare key stored.key in
          if compared = 0 then
            (Some stored, List.rev_append reversed rest)
          else if compared < 0 then
            (None, List.rev_append reversed (stored :: rest))
          else loop (stored :: reversed) rest
    in
    loop [] entries

  let insert compare entry entries =
    let rec loop reversed = function
      | [] -> List.rev (entry :: reversed)
      | stored :: _ as rest when compare entry.key stored.key < 0 ->
          List.rev_append reversed (entry :: rest)
      | stored :: rest ->
          loop (stored :: reversed) rest
    in
    loop [] entries

  let apply_updates recipient updates =
    let rec loop delivered = function
      | [] -> Ok delivered
      | Attached entry :: rest ->
          let active, delivered =
            find_and_remove recipient.harness.key_compare entry.key delivered
          in
          if Option.is_some active then Error Invalid_transition
          else
            loop
              (insert recipient.harness.key_compare entry delivered)
              rest
      | Changed entry :: rest ->
          let active, delivered =
            find_and_remove recipient.harness.key_compare entry.key delivered
          in
          (match active with
          | Some active
            when Int64.equal active.incarnation entry.incarnation ->
              loop
                (insert recipient.harness.key_compare entry delivered)
                rest
          | Some _ | None -> Error Invalid_transition)
      | Removed removed :: rest ->
          let active, delivered =
            find_and_remove recipient.harness.key_compare removed.key delivered
          in
          (match active with
          | Some active
            when Int64.equal active.incarnation removed.incarnation ->
              (match rest with
              | Attached replacement :: _
                when recipient.harness.key_compare removed.key
                       replacement.key
                     = 0
                     && Int64.equal removed.incarnation
                          replacement.incarnation ->
                  Error Invalid_transition
              | _ -> loop delivered rest)
          | Some _ | None -> Error Invalid_transition)
    in
    loop recipient.delivered updates

  let install recipient delivered =
    if recipient.fail_next_install then (
      recipient.fail_next_install <- false;
      Error Install_failed)
    else (
      recipient.delivered <- delivered;
      recipient.installed <- true;
      Ok ())

  let apply recipient frame =
    match frame with
    | Crux.Wire.Frame.Projection_deliver
        { reason = `Advancement; content = Updates updates; _ } ->
        if List.length updates > recipient.capacity then
          Error Capacity_exceeded
        else
          let* updates =
            decode_all (decode_update recipient.harness) updates
          in
          let* () = canonical_updates recipient.harness updates in
          let* delivered = apply_updates recipient updates in
          if List.length delivered > recipient.capacity then
            Error Capacity_exceeded
          else install recipient delivered
    | Projection_deliver
        {
          reason = `Session_replacement;
          content = Bootstrap entries;
          _;
        } ->
        if List.length entries > recipient.capacity then
          Error Capacity_exceeded
        else
          let* entries =
            decode_all (decode_entry recipient.harness) entries
          in
          let* () = canonical_entries recipient.harness entries in
          install recipient entries
    | Projection_deliver _ -> Error Invalid_transition
    | Projection_result _ | Crash_notify _ | Crash_result _
    | Endpoint_invoke _ | Endpoint_result _ | Request_start _
    | Request_start_result _ | Request_dispatch _
    | Request_dispatch_result _ | Request_resolve _
    | Request_resolve_result _ | Request_cancel _
    | Request_cancel_result _ | Request_resolved _
    | Request_closed _ ->
        Error Invalid_transition
end

module Opaque = struct
  let codec =
    Crux.Codec.make
      ~encode:(fun _ -> Ok Bytes.empty)
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "opaque identity-binding projection cannot be decoded";
          })

  let harness =
    create ~name:"eta_crux_test.opaque" ~codec
      ~value_equal:(fun _ _ -> false) ~cutoff:Crux.Cutoff.never

  let root ?post_commit_effect_observer ~projection_capacity
      ~ingress_capacity ~request_capacity description =
    let description = Crux.map description ~f:Obj.repr in
    root ?post_commit_effect_observer harness ~projection_capacity
      ~ingress_capacity ~request_capacity description

  let snapshot_value snapshot =
    snapshot_value harness snapshot |> Option.map Obj.obj

  let commit_value commit =
    commit_value harness commit |> Option.map Obj.obj

  let delivery_value delivery =
    delivery_value harness delivery |> Option.map Obj.obj
end
