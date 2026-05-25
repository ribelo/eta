let test_pp_redacts_value () =
  let redacted = Redacted.make "secret" in
  Alcotest.(check string) "pp" "<redacted>"
    (Format.asprintf "%a" Redacted.pp redacted)

let test_pp_uses_label () =
  let redacted = Redacted.make ~label:"api_key" "secret" in
  Alcotest.(check string) "labelled pp" "<redacted:api_key>"
    (Format.asprintf "%a" Redacted.pp redacted)

let test_equal_uses_value () =
  let a = Redacted.make "x" in
  let b = Redacted.make "x" in
  let c = Redacted.make "y" in
  Alcotest.(check bool) "equal same" true (Redacted.equal String.equal a b);
  Alcotest.(check bool) "equal different" false
    (Redacted.equal String.equal a c)

let test_hash_uses_value () =
  let a = Redacted.make "x" in
  let b = Redacted.make "x" in
  Alcotest.(check int) "hash same" (Redacted.hash String.hash a)
    (Redacted.hash String.hash b)

let test_wipe_erases_value () =
  let redacted = Redacted.make "secret" in
  Alcotest.(check bool) "wipe returns true" true
    (Redacted.wipe_unsafe redacted);
  Alcotest.check_raises "value after wipe" (Failure "Redacted.value: wiped")
    (fun () -> ignore (Redacted.value redacted))

let test_label_round_trips () =
  let a = Redacted.make "secret" in
  let b = Redacted.make ~label:"token" "secret" in
  Alcotest.(check (option string)) "no label" None (Redacted.label a);
  Alcotest.(check (option string)) "with label" (Some "token")
    (Redacted.label b)

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
