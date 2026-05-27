open Eta
open Eta_test
open Test_eta_support

let test_redacted_pp_unlabelled () =
  let r = Eta_redacted.make "secret" in
  Alcotest.(check string) "unlabelled pp" "<redacted>"
    (Format.asprintf "%a" Eta_redacted.pp r)

let test_redacted_pp_labelled () =
  let r = Eta_redacted.make ~label:"api_key" "secret" in
  Alcotest.(check string) "labelled pp" "<redacted:api_key>"
    (Format.asprintf "%a" Eta_redacted.pp r)

let test_redacted_equal () =
  let a = Eta_redacted.make "x" in
  let b = Eta_redacted.make "x" in
  let c = Eta_redacted.make "y" in
  Alcotest.(check bool) "equal same" true (Eta_redacted.equal String.equal a b);
  Alcotest.(check bool) "equal different" false (Eta_redacted.equal String.equal a c)

let test_redacted_hash () =
  let a = Eta_redacted.make "x" in
  let b = Eta_redacted.make "x" in
  Alcotest.(check int) "hash stable"
    (Eta_redacted.hash String.hash a)
    (Eta_redacted.hash String.hash b)

let test_redacted_wipe_unsafe () =
  let r = Eta_redacted.make "secret" in
  Alcotest.(check bool) "wipe returns true" true (Eta_redacted.wipe_unsafe r);
  Alcotest.check_raises "value after wipe" (Failure "Eta_redacted.value: wiped")
    (fun () -> ignore (Eta_redacted.value r))

let test_redacted_label () =
  let a = Eta_redacted.make "secret" in
  let b = Eta_redacted.make ~label:"token" "secret" in
  Alcotest.(check (option string)) "no label" None (Eta_redacted.label a);
  Alcotest.(check (option string)) "with label" (Some "token") (Eta_redacted.label b)


