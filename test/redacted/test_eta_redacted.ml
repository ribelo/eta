let test_pp_redacts_value () =
  let redacted = Eta_redacted.make "secret" in
  Alcotest.(check string) "pp" "<redacted>"
    (Format.asprintf "%a" Eta_redacted.pp redacted)

let test_pp_uses_label () =
  let redacted = Eta_redacted.make ~label:"api_key" "secret" in
  Alcotest.(check string) "labelled pp" "<redacted:api_key>"
    (Format.asprintf "%a" Eta_redacted.pp redacted)

let test_equal_uses_value () =
  let a = Eta_redacted.make "x" in
  let b = Eta_redacted.make "x" in
  let c = Eta_redacted.make "y" in
  Alcotest.(check bool) "equal same" true (Eta_redacted.equal String.equal a b);
  Alcotest.(check bool) "equal different" false
    (Eta_redacted.equal String.equal a c)

let test_hash_uses_value () =
  let a = Eta_redacted.make "x" in
  let b = Eta_redacted.make "x" in
  Alcotest.(check int) "hash same" (Eta_redacted.hash String.hash a)
    (Eta_redacted.hash String.hash b)

let test_wipe_erases_value () =
  let redacted = Eta_redacted.make "secret" in
  Alcotest.(check bool) "wipe returns true" true
    (Eta_redacted.wipe_unsafe redacted);
  Alcotest.check_raises "value after wipe" (Failure "Eta_redacted.value: wiped")
    (fun () -> ignore (Eta_redacted.value redacted))

let test_label_round_trips () =
  let a = Eta_redacted.make "secret" in
  let b = Eta_redacted.make ~label:"token" "secret" in
  Alcotest.(check (option string)) "no label" None (Eta_redacted.label a);
  Alcotest.(check (option string)) "with label" (Some "token")
    (Eta_redacted.label b)

let () =
  Alcotest.run "eta-redacted"
    [
      ( "redacted",
        [
          Alcotest.test_case "pp redacts value" `Quick test_pp_redacts_value;
          Alcotest.test_case "pp uses label" `Quick test_pp_uses_label;
          Alcotest.test_case "equal uses value" `Quick test_equal_uses_value;
          Alcotest.test_case "hash uses value" `Quick test_hash_uses_value;
          Alcotest.test_case "wipe erases value" `Quick test_wipe_erases_value;
          Alcotest.test_case "label round-trips" `Quick test_label_round_trips;
        ] );
    ]
