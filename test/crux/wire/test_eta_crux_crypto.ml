let hex bytes =
  Bytes.to_seq bytes
  |> Seq.map (fun value ->
         Printf.sprintf "%02x" (Char.code value))
  |> List.of_seq |> String.concat ""

let test_sha256 () =
  Alcotest.(check string) "SHA-256 vector"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (Crux_sha256.digest (Bytes.of_string "abc") |> hex)

let test_hmac_sha256 () =
  Alcotest.(check string) "HMAC-SHA-256 vector"
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    (Crux_sha256.hmac ~key:(String.make 20 '\x0b')
       (Bytes.of_string "Hi There")
    |> hex)

let () =
  Alcotest.run "eta_crux crypto"
    [
      ( "vectors",
        [
          Alcotest.test_case "SHA-256" `Quick test_sha256;
          Alcotest.test_case "HMAC-SHA-256" `Quick
            test_hmac_sha256;
        ] );
    ]
