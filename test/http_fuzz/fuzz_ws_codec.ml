open Eta_http_fuzz_support

let data_opcode_gen =
  Crowbar.choose
    [
      Crowbar.const Eta_http.Ws.Codec.Continuation;
      Crowbar.const Eta_http.Ws.Codec.Text;
      Crowbar.const Eta_http.Ws.Codec.Binary;
    ]

let control_opcode_gen =
  Crowbar.choose
    [
      Crowbar.const Eta_http.Ws.Codec.Close;
      Crowbar.const Eta_http.Ws.Codec.Ping;
      Crowbar.const Eta_http.Ws.Codec.Pong;
    ]

let data_frame_gen =
  Crowbar.map
    [ Crowbar.bool; data_opcode_gen; bounded_bytes 192 ]
    (fun fin opcode payload -> { Eta_http.Ws.Codec.fin; opcode; payload })

let control_frame_gen =
  Crowbar.map
    [ control_opcode_gen; bounded_bytes 125 ]
    (fun opcode payload -> { Eta_http.Ws.Codec.fin = true; opcode; payload })

let frame_gen = Crowbar.choose [ data_frame_gen; control_frame_gen ]
let mask_gen = bytes_of_string_gen 4

let check_frame expected actual =
  Crowbar.check_eq ~pp:Crowbar.pp_bool expected.Eta_http.Ws.Codec.fin
    actual.Eta_http.Ws.Codec.fin;
  Crowbar.check_eq
    ~pp:(fun fmt opcode ->
      Format.pp_print_int fmt (Eta_http.Ws.Codec.opcode_to_int opcode))
    expected.opcode actual.opcode;
  check_same_bytes "payload" expected.payload actual.payload

let () =
  Crowbar.add_test ~name:"ws decode arbitrary bytes does not escape"
    [ bounded_bytes 192; Crowbar.bool ] (fun bytes masked ->
      ignore
        (Eta_http.Ws.Codec.decode ~masked bytes
          : (Eta_http.Ws.Codec.frame * int, Eta_http.Ws.Codec.parse_error)
            result));

  Crowbar.add_test ~name:"ws unmasked frame roundtrip" [ frame_gen ]
    (fun frame ->
      let encoded = Eta_http.Ws.Codec.encode frame in
      match Eta_http.Ws.Codec.decode encoded with
      | Error error ->
          Crowbar.failf "decode rejected encoded frame: %s"
            (Eta_http.Ws.Codec.parse_error_to_string error)
      | Ok (actual, consumed) ->
          Crowbar.check_eq ~pp:Crowbar.pp_int (Bytes.length encoded) consumed;
          check_frame frame actual);

  Crowbar.add_test ~name:"ws masked frame roundtrip" [ mask_gen; frame_gen ]
    (fun mask frame ->
      let encoded = Eta_http.Ws.Codec.encode ~mask frame in
      match Eta_http.Ws.Codec.decode ~masked:true encoded with
      | Error error ->
          Crowbar.failf "decode rejected encoded masked frame: %s"
            (Eta_http.Ws.Codec.parse_error_to_string error)
      | Ok (actual, consumed) ->
          Crowbar.check_eq ~pp:Crowbar.pp_int (Bytes.length encoded) consumed;
          check_frame frame actual)
