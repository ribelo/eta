let hpack_header name value =
  { Eta_http.Hpack.name; value; sensitive = false }

let raw_string_literal s =
  let len = String.length s in
  if len > 127 then invalid_arg "raw_string_literal only supports short strings";
  String.make 1 (Char.chr len) ^ s

let literal_with_indexing ~name ~value =
  String.make 1 (Char.chr 0x40)
  ^ raw_string_literal name
  ^ raw_string_literal value

let indexed index =
  if index <= 0 || index >= 128 then
    invalid_arg "indexed only supports one-byte HPACK indexes";
  String.make 1 (Char.chr (0x80 lor index))

let dynamic_table_size_update capacity =
  if capacity < 0 || capacity >= 31 then
    invalid_arg
      "dynamic_table_size_update only supports one-byte HPACK capacities";
  String.make 1 (Char.chr (0x20 lor capacity))

let decode_ok decoder block =
  match Eta_http.Hpack.decode_headers_string decoder block with
  | Ok headers -> headers
  | Error _ -> Alcotest.fail "HPACK decode failed"

let header_pairs headers =
  headers

let check_headers label expected headers =
  Alcotest.(check (list (pair string string)))
    label expected (header_pairs headers)

let test_hpack_dynamic_table_indexes_after_eviction () =
  let decoder = Eta_http.Hpack.create 80 in
  ignore
    (decode_ok decoder (literal_with_indexing ~name:"x-a" ~value:"one")
      : (string * string) list);
  ignore
    (decode_ok decoder (literal_with_indexing ~name:"x-b" ~value:"two")
      : (string * string) list);
  check_headers "third literal"
    [ ("x-c", "three") ]
    (decode_ok decoder (literal_with_indexing ~name:"x-c" ~value:"three"));
  check_headers "newest dynamic index"
    [ ("x-c", "three") ]
    (decode_ok decoder (indexed 62));
  check_headers "older dynamic index"
    [ ("x-b", "two") ]
    (decode_ok decoder (indexed 63))

let test_hpack_dynamic_table_size_update_evicts_entries () =
  let decoder = Eta_http.Hpack.create 4096 in
  ignore
    (decode_ok decoder (literal_with_indexing ~name:"x-a" ~value:"one")
      : (string * string) list);
  check_headers "indexed before resize"
    [ ("x-a", "one") ]
    (decode_ok decoder (indexed 62));
  check_headers "resize header block" []
    (decode_ok decoder (dynamic_table_size_update 0));
  match Eta_http.Hpack.decode_headers_string decoder (indexed 62) with
  | Ok _ -> Alcotest.fail "evicted dynamic index decoded"
  | Error _ -> ()

let test_hpack_encoder_respects_zero_peer_table_size () =
  let encoder = Eta_http.Hpack.encoder_create 4096 in
  Eta_http.Hpack.encoder_set_max_table_size encoder 0;
  let block =
    Eta_http.Hpack.encode_headers encoder [ hpack_header "x-a" "one" ]
  in
  Alcotest.(check int)
    "size update" 0x20
    (Char.code (String.unsafe_get block 0));
  Alcotest.(check int)
    "literal without indexing" 0x00
    (Char.code (String.unsafe_get block 1));
  let decoder = Eta_http.Hpack.create 4096 in
  check_headers "decoded header"
    [ ("x-a", "one") ]
    (decode_ok decoder block);
  Alcotest.(check int)
    "dynamic entries" 0
    (Eta_http.Hpack.dynamic_table_size decoder)

let test_hpack_decode_truncated_string_returns_error () =
  let decoder = Eta_http.Hpack.create 4096 in
  let malformed = String.make 1 (Char.chr 0x40) ^ "\003x" in
  match Eta_http.Hpack.decode_headers_string decoder malformed with
  | Ok _ -> Alcotest.fail "truncated string decoded"
  | Error _ -> ()

let test_hpack_encoder_handles_large_header_block () =
  let value = String.make 5000 'x' in
  let encoder = Eta_http.Hpack.encoder_create 4096 in
  let block =
    Eta_http.Hpack.encode_headers encoder [ hpack_header "x-large" value ]
  in
  let decoder = Eta_http.Hpack.create 4096 in
  check_headers "decoded large header"
    [ ("x-large", value) ]
    (decode_ok decoder block)
