open Eta
open Eta_test
open Test_eta_support

let test_redacted_pp_unlabelled () =
  let r = Redacted.make "secret" in
  Alcotest.(check string) "unlabelled pp" "<redacted>"
    (Format.asprintf "%a" Redacted.pp r)

let test_redacted_pp_labelled () =
  let r = Redacted.make ~label:"api_key" "secret" in
  Alcotest.(check string) "labelled pp" "<redacted:api_key>"
    (Format.asprintf "%a" Redacted.pp r)

let test_redacted_equal () =
  let a = Redacted.make "x" in
  let b = Redacted.make "x" in
  let c = Redacted.make "y" in
  Alcotest.(check bool) "equal same" true (Redacted.equal String.equal a b);
  Alcotest.(check bool) "equal different" false (Redacted.equal String.equal a c)

let test_redacted_hash () =
  let a = Redacted.make "x" in
  let b = Redacted.make "x" in
  Alcotest.(check int) "hash stable"
    (Redacted.hash String.hash a)
    (Redacted.hash String.hash b)

let test_redacted_wipe_unsafe () =
  let r = Redacted.make "secret" in
  Alcotest.(check bool) "wipe returns true" true (Redacted.wipe_unsafe r);
  Alcotest.check_raises "value after wipe" (Failure "Redacted.value: wiped")
    (fun () -> ignore (Redacted.value r))

let test_redacted_label () =
  let a = Redacted.make "secret" in
  let b = Redacted.make ~label:"token" "secret" in
  Alcotest.(check (option string)) "no label" None (Redacted.label a);
  Alcotest.(check (option string)) "with label" (Some "token") (Redacted.label b)


