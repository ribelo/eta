module Crux = Eta_crux
module Harness = Eta_crux_test.Projection_harness
module Recipient = Harness.Wire_recipient

let shared_runtime : Crux.never Eta.Runtime.t option ref = ref None

let run_ok effect =
  match !shared_runtime with
  | None -> failwith "projection-wire-law runtime is not installed"
  | Some runtime ->
      Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let codec encode decode =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (encode value)))
    ~decode:(fun bytes ->
      match decode (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid wire-law value" })

let int_codec = codec string_of_int int_of_string_opt

let harness () =
  Harness.Keyed.create ~name:"wire.law" ~key_compare:Int.compare
    ~key_codec:int_codec ~value_codec:int_codec ~value_equal:Int.equal
    ~cutoff:Crux.Cutoff.never

let entry ?(kind = "wire.law") ?(key = 1) ?(incarnation = 1L)
    ?(value = 10) () =
  {
    Crux.Wire.Frame.kind;
    key = Bytes.of_string (string_of_int key);
    incarnation;
    value = Bytes.of_string (string_of_int value);
  }

let removed ?(kind = "wire.law") ?(key = 1) ?(incarnation = 1L) () =
  Crux.Wire.Frame.Removed
    {
      kind;
      key = Bytes.of_string (string_of_int key);
      incarnation;
    }

let advancement updates =
  Crux.Wire.Frame.Projection_deliver
    {
      seq = 0l;
      reason = `Advancement;
      content = Updates updates;
    }

let bootstrap entries =
  Crux.Wire.Frame.Projection_deliver
    {
      seq = 0l;
      reason = `Session_replacement;
      content = Bootstrap entries;
    }

let formats =
  [
    ("json", (module Eta_crux_json.Format : Crux.Wire.FORMAT));
    ("sexp", (module Eta_crux_sexp.Format : Crux.Wire.FORMAT));
  ]

type update_shape =
  | Attach
  | Change
  | Remove
  | Boot

let update_shape =
  QCheck.make
    ~print:(function
      | Attach -> "attach"
      | Change -> "change"
      | Remove -> "remove"
      | Boot -> "bootstrap")
    QCheck.Gen.(oneof_list [ Attach; Change; Remove; Boot ])

(* Generated class: every projection item shape with bounded key/value bytes.
   Observation boundary: both public format round trips and exact semantic
   fields. *)
let qcheck_projection_wire_entry_structure =
  QCheck.Test.make ~name:"qcheck_projection_wire_entry_structure" ~count:80
    QCheck.(triple update_shape (int_range 0 1_000) (int_range (-1_000) 1_000))
    (fun (shape, key, value) ->
      let expected =
        match shape with
        | Attach ->
            advancement
              [ Crux.Wire.Frame.Attached (entry ~key ~value ()) ]
        | Change ->
            advancement
              [ Crux.Wire.Frame.Changed (entry ~key ~value ()) ]
        | Remove -> advancement [ removed ~key () ]
        | Boot -> bootstrap [ entry ~key ~value () ]
      in
      List.for_all
        (fun (_, (module Format : Crux.Wire.FORMAT)) ->
          match Format.decode (Format.encode expected) with
          | Ok actual -> actual = expected
          | Error _ -> false)
        formats)

let shuffled_unique =
  let open QCheck.Gen in
  let* size = 2 -- 10 in
  let values = List.init size Fun.id in
  shuffle_list values

(* Generated class: every permutation of two to ten unique keys.
   Observation boundary: the configured recipient accepts only ascending
   canonical order and never repairs another permutation. *)
let qcheck_projection_wire_order_rejection =
  QCheck.Test.make ~name:"qcheck_projection_wire_order_rejection" ~count:80
    (QCheck.make ~print:QCheck.Print.(list int) shuffled_unique)
    (fun keys ->
      let recipient = Recipient.create (harness ()) ~capacity:10 in
      let result =
        Recipient.apply recipient
          (bootstrap (List.map (fun key -> entry ~key ()) keys))
      in
      if keys = List.sort Int.compare keys then result = Ok ()
      else result = Error Recipient.Noncanonical_order)

(* Generated class: wrong flat S-expression item counts.
   Observation boundary: the public decoder rejects every mismatch. *)
let qcheck_projection_wire_count_exactness =
  QCheck.Test.make ~name:"qcheck_projection_wire_count_exactness" ~count:50
    QCheck.(pair (int_range 0 8) (int_range 0 8))
    (fun (actual, declared) ->
      let canonical =
        bootstrap
          (List.init actual (fun key -> entry ~key ()))
        |> Eta_crux_sexp.Format.encode
        |> Bytes.to_string
      in
      let tokens = String.split_on_char ' ' canonical in
      let tokens =
        List.mapi
          (fun index token ->
            if index = 4 then string_of_int declared else token)
          tokens
      in
      let encoded = String.concat " " tokens in
      match Eta_crux_sexp.Format.decode (Bytes.of_string encoded) with
      | Ok _ -> actual = declared
      | Error _ -> actual <> declared)

(* Generated class: valid UTF-8 diagnostics at the 1,024-byte bound and one
   byte over. Observation boundary: session validation accepts the bound and
   rejects the over-bound result field. *)
let qcheck_projection_result_diagnostic =
  QCheck.Test.make ~name:"qcheck_projection_result_diagnostic" ~count:30
    (QCheck.make QCheck.Gen.(oneof_list [ 1_023; 1_024; 1_025 ]))
    (fun length ->
      let frame =
        Crux.Wire.Frame.Projection_result
          {
            seq = 0l;
            reply_to = 0l;
            result = `Failed (String.make length 'x');
          }
      in
      let round_trips =
        List.for_all
          (fun (_, (module Format : Crux.Wire.FORMAT)) ->
            match Format.decode (Format.encode frame) with
            | Ok actual -> actual = frame
            | Error _ -> false)
          formats
      in
      let _candidate, peer =
        Crux.Serialized_session.candidate ~max_frame_bytes:8_192
          ~format:(module Eta_crux_json.Format)
      in
      let received =
        run_ok
          (Crux.Serialized_session.receive peer
             (Eta_crux_json.Format.encode frame))
      in
      round_trips
      &&
      match received with
      | Error
          (Crux.Serialized_session.Protocol_error
            Crux.Wire.Invalid_field) ->
          length > 1_024
      | Error
          (Crux.Serialized_session.Protocol_error
            Crux.Wire.Unknown_reply) ->
          length <= 1_024
      | Ok () | Error Crux.Serialized_session.Session_closed
      | Error (Crux.Serialized_session.Protocol_error _) ->
          false)

type rejection_case =
  | Unknown_kind
  | Invalid_key
  | Zero_incarnation
  | Noncanonical_order
  | Duplicate_identity
  | Invalid_transition
  | Codec_error
  | Capacity_exceeded

let rejection_case =
  QCheck.make
    ~print:(function
      | Unknown_kind -> "unknown_kind"
      | Invalid_key -> "invalid_key"
      | Zero_incarnation -> "zero_incarnation"
      | Noncanonical_order -> "noncanonical_order"
      | Duplicate_identity -> "duplicate_identity"
      | Invalid_transition -> "invalid_transition"
      | Codec_error -> "codec_error"
      | Capacity_exceeded -> "capacity_exceeded")
    QCheck.Gen.(
      oneof_list
        [
          Unknown_kind;
          Invalid_key;
          Zero_incarnation;
          Noncanonical_order;
          Duplicate_identity;
          Invalid_transition;
          Codec_error;
          Capacity_exceeded;
        ])

(* Generated class: one payload violation per delivery, covering all eight
   rejection classes. Observation boundary: exact rejection, unchanged
   recipient state, and continued usability. *)
let qcheck_projection_payload_rejection =
  QCheck.Test.make ~name:"qcheck_projection_payload_rejection" ~count:80
    rejection_case (fun case ->
      let recipient = Recipient.create (harness ()) ~capacity:2 in
      let frame, expected =
        match case with
        | Unknown_kind ->
            ( bootstrap [ entry ~kind:"unknown" () ],
              Recipient.Unknown_kind )
        | Invalid_key ->
            let malformed = entry () in
            ( bootstrap
                [ { malformed with key = Bytes.of_string "not-an-int" } ],
              Recipient.Invalid_key )
        | Zero_incarnation ->
            (bootstrap [ entry ~incarnation:0L () ], Recipient.Zero_incarnation)
        | Noncanonical_order ->
            ( bootstrap [ entry ~key:2 (); entry ~key:1 () ],
              Recipient.Noncanonical_order )
        | Duplicate_identity ->
            ( bootstrap [ entry ~key:1 (); entry ~key:1 () ],
              Recipient.Duplicate_identity )
        | Invalid_transition ->
            ( advancement [ Crux.Wire.Frame.Changed (entry ()) ],
              Recipient.Invalid_transition )
        | Codec_error ->
            let malformed = entry () in
            ( bootstrap
                [ { malformed with value = Bytes.of_string "not-an-int" } ],
              Recipient.Codec_error )
        | Capacity_exceeded ->
            ( bootstrap [ entry ~key:1 (); entry ~key:2 (); entry ~key:3 () ],
              Recipient.Capacity_exceeded )
      in
      Recipient.apply recipient frame = Error expected
      && not (Recipient.installed recipient)
      && Recipient.delivered_count recipient = 0
      && Recipient.apply recipient (bootstrap [ entry () ]) = Ok ())

(* Generated class: raw frame sizes exactly at and one byte beyond the
   configured receive bound. Observation boundary: public receive result. *)
let qcheck_projection_frame_size_boundary =
  QCheck.Test.make ~name:"qcheck_projection_frame_size_boundary" ~count:30
    QCheck.(int_range 0 256) (fun padding ->
      let frame =
        bootstrap
          [ { (entry ()) with value = Bytes.make padding 'x' } ]
      in
      let bytes = Eta_crux_json.Format.encode frame in
      let at_bound, at_peer =
        Crux.Serialized_session.candidate
          ~max_frame_bytes:(Bytes.length bytes)
          ~format:(module Eta_crux_json.Format)
      in
      let over_bound, over_peer =
        Crux.Serialized_session.candidate
          ~max_frame_bytes:(max 1 (Bytes.length bytes - 1))
          ~format:(module Eta_crux_json.Format)
      in
      ignore at_bound;
      ignore over_bound;
      run_ok (Crux.Serialized_session.receive at_peer bytes) = Ok ()
      &&
      match run_ok (Crux.Serialized_session.receive over_peer bytes) with
      | Error (Crux.Serialized_session.Protocol_error Crux.Wire.Frame_too_large) ->
          true
      | _ -> false)

(* Generated class: canonical decimal keys and equivalent leading-zero
   encodings. Observation boundary: decode/re-encode byte equality at the
   recipient. *)
let qcheck_projection_wire_key_canonicality =
  QCheck.Test.make ~name:"qcheck_projection_wire_key_canonicality" ~count:50
    QCheck.(int_range 0 100_000) (fun key ->
      let recipient = Recipient.create (harness ()) ~capacity:1 in
      let canonical = Recipient.apply recipient (bootstrap [ entry ~key () ]) in
      let noncanonical_entry =
        {
          (entry ~key ()) with
          key = Bytes.of_string ("0" ^ string_of_int key);
        }
      in
      let noncanonical_recipient =
        Recipient.create (harness ()) ~capacity:1
      in
      canonical = Ok ()
      && Recipient.apply noncanonical_recipient
           (bootstrap [ noncanonical_entry ])
         = Error Recipient.Noncanonical_key)

type transition_case =
  | Legal_change
  | Legal_remove_attach
  | Wrong_change_incarnation
  | Reused_replacement_incarnation
  | Attach_while_active
  | Remove_absent

let transition_case =
  QCheck.make
    ~print:(function
      | Legal_change -> "legal_change"
      | Legal_remove_attach -> "legal_remove_attach"
      | Wrong_change_incarnation -> "wrong_change_incarnation"
      | Reused_replacement_incarnation ->
          "reused_replacement_incarnation"
      | Attach_while_active -> "attach_while_active"
      | Remove_absent -> "remove_absent")
    QCheck.Gen.(
      oneof_list
        [
          Legal_change;
          Legal_remove_attach;
          Wrong_change_incarnation;
          Reused_replacement_incarnation;
          Attach_while_active;
          Remove_absent;
        ])

(* Generated class: legal and illegal transitions from one accepted snapshot.
   Observation boundary: complete recipient state and atomic failure. *)
let qcheck_projection_shell_transition_validation =
  QCheck.Test.make ~name:"qcheck_projection_shell_transition_validation"
    ~count:60 transition_case (fun case ->
      let recipient = Recipient.create (harness ()) ~capacity:2 in
      let initial = bootstrap [ entry ~value:10 () ] in
      if Recipient.apply recipient initial <> Ok () then false
      else
        let updates, expected, value =
          match case with
          | Legal_change ->
              ( [ Crux.Wire.Frame.Changed (entry ~value:20 ()) ],
                Ok (),
                Some 20 )
          | Legal_remove_attach ->
              ( [ removed (); Crux.Wire.Frame.Attached
                                    (entry ~incarnation:2L ~value:30 ()) ],
                Ok (),
                Some 30 )
          | Wrong_change_incarnation ->
              ( [ Crux.Wire.Frame.Changed
                    (entry ~incarnation:2L ~value:20 ()) ],
                Error Recipient.Invalid_transition,
                Some 10 )
          | Reused_replacement_incarnation ->
              ( [ removed ();
                  Crux.Wire.Frame.Attached
                    (entry ~incarnation:1L ~value:30 ()) ],
                Error Recipient.Invalid_transition,
                Some 10 )
          | Attach_while_active ->
              ( [ Crux.Wire.Frame.Attached
                    (entry ~incarnation:2L ~value:20 ()) ],
                Error Recipient.Invalid_transition,
                Some 10 )
          | Remove_absent ->
              ( [ removed ~key:2 () ],
                Error Recipient.Invalid_transition,
                Some 10 )
        in
        Recipient.apply recipient (advancement updates) = expected
        && Recipient.find_value recipient ~key:1 = value)

(* Generated class: both reasons and both content constructors. Observation
   boundary: both public decoders accept exactly the two legal pairings. *)
let qcheck_projection_bp_reason_content_pairing =
  QCheck.Test.make ~name:"qcheck_projection_bp_reason_content_pairing"
    ~count:40 QCheck.(pair bool bool) (fun (replacement, bootstrap_content) ->
      let reason =
        if replacement then `Session_replacement else `Advancement
      in
      let content =
        if bootstrap_content then Crux.Wire.Frame.Bootstrap []
        else Updates []
      in
      let frame =
        Crux.Wire.Frame.Projection_deliver
          { seq = 0l; reason; content }
      in
      let valid = replacement = bootstrap_content in
      List.for_all
        (fun (_, (module Format : Crux.Wire.FORMAT)) ->
          match Format.decode (Format.encode frame) with
          | Ok _ -> valid
          | Error _ -> not valid)
        formats)

let () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  shared_runtime := Some runtime;
  let seed = Random.State.make [| 0xE7A; 0xC2; 0x71 |] in
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:seed
      [
        qcheck_projection_wire_entry_structure;
        qcheck_projection_wire_order_rejection;
        qcheck_projection_wire_count_exactness;
        qcheck_projection_result_diagnostic;
        qcheck_projection_payload_rejection;
        qcheck_projection_frame_size_boundary;
        qcheck_projection_wire_key_canonicality;
        qcheck_projection_shell_transition_validation;
        qcheck_projection_bp_reason_content_pairing;
      ]
  in
  if code <> 0 then exit code
