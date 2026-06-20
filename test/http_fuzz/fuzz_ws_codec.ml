open Eta_http_fuzz_support

let data_opcode_gen =
  Crowbar.choose
    [
      Crowbar.const Eta_http_ws.Codec.Continuation;
      Crowbar.const Eta_http_ws.Codec.Text;
      Crowbar.const Eta_http_ws.Codec.Binary;
    ]

let control_opcode_gen =
  Crowbar.choose
    [
      Crowbar.const Eta_http_ws.Codec.Ping;
      Crowbar.const Eta_http_ws.Codec.Pong;
    ]

let data_frame_gen =
  Crowbar.map
    [ Crowbar.bool; data_opcode_gen; bounded_bytes 192 ]
    (fun fin opcode payload -> { Eta_http_ws.Codec.fin; opcode; payload })

let control_frame_gen =
  Crowbar.map
    [ control_opcode_gen; bounded_bytes 125 ]
    (fun opcode payload -> { Eta_http_ws.Codec.fin = true; opcode; payload })

let valid_close_code_gen =
  Crowbar.choose
    [
      Crowbar.const 1000;
      Crowbar.const 1001;
      Crowbar.const 1002;
      Crowbar.const 1003;
      Crowbar.const 1007;
      Crowbar.const 1008;
      Crowbar.const 1009;
      Crowbar.const 1010;
      Crowbar.const 1011;
      Crowbar.const 1012;
      Crowbar.const 1013;
      Crowbar.const 1014;
      Crowbar.map [ Crowbar.range 1000 ] (fun offset -> 3000 + offset);
      Crowbar.map [ Crowbar.range 1000 ] (fun offset -> 4000 + offset);
    ]

let close_payload code reason =
  let payload = Bytes.create (2 + Bytes.length reason) in
  Bytes.set_int16_be payload 0 code;
  Bytes.blit reason 0 payload 2 (Bytes.length reason);
  payload

let close_frame_gen =
  Crowbar.choose
    [
      Crowbar.const
        {
          Eta_http_ws.Codec.fin = true;
          opcode = Eta_http_ws.Codec.Close;
          payload = Bytes.empty;
        };
      Crowbar.map [ valid_close_code_gen; bounded_bytes 123 ] (fun code reason ->
          {
            Eta_http_ws.Codec.fin = true;
            opcode = Eta_http_ws.Codec.Close;
            payload = close_payload code reason;
          });
    ]

let frame_gen = Crowbar.choose [ data_frame_gen; control_frame_gen; close_frame_gen ]
let mask_gen = bytes_of_string_gen 4

let check_frame expected actual =
  Crowbar.check_eq ~pp:Crowbar.pp_bool expected.Eta_http_ws.Codec.fin
    actual.Eta_http_ws.Codec.fin;
  Crowbar.check_eq
    ~pp:(fun fmt opcode ->
      Format.pp_print_int fmt (Eta_http_ws.Codec.opcode_to_int opcode))
    expected.opcode actual.opcode;
  check_same_bytes "payload" expected.payload actual.payload

let () =
  Crowbar.add_test ~name:"ws decode arbitrary bytes does not escape"
    [ bounded_bytes 192; Crowbar.bool ] (fun bytes masked ->
      ignore
        (Eta_http_ws.Codec.decode ~masked bytes
          : (Eta_http_ws.Codec.frame * int, Eta_http_ws.Codec.parse_error)
            result));

  Crowbar.add_test ~name:"ws unmasked frame roundtrip" [ frame_gen ]
    (fun frame ->
      let encoded = Eta_http_ws.Codec.encode frame in
      match Eta_http_ws.Codec.decode encoded with
      | Error error ->
          Crowbar.failf "decode rejected encoded frame: %s"
            (Eta_http_ws.Codec.parse_error_to_string error)
      | Ok (actual, consumed) ->
          Crowbar.check_eq ~pp:Crowbar.pp_int (Bytes.length encoded) consumed;
          check_frame frame actual);

  Crowbar.add_test ~name:"ws masked frame roundtrip" [ mask_gen; frame_gen ]
    (fun mask frame ->
      let encoded = Eta_http_ws.Codec.encode ~mask frame in
      match Eta_http_ws.Codec.decode ~masked:true encoded with
      | Error error ->
          Crowbar.failf "decode rejected encoded masked frame: %s"
            (Eta_http_ws.Codec.parse_error_to_string error)
      | Ok (actual, consumed) ->
          Crowbar.check_eq ~pp:Crowbar.pp_int (Bytes.length encoded) consumed;
          check_frame frame actual)
