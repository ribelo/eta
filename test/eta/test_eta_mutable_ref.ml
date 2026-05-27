open Eta
open Eta_test
open Test_eta_support

let test_mutable_ref_make_get () =
  let r = Mutable_ref.make 42 in
  Alcotest.(check int) "make then get" 42 (Mutable_ref.get r)

let test_mutable_ref_set () =
  let r = Mutable_ref.make 0 in
  Mutable_ref.set r 7;
  Alcotest.(check int) "set overwrites" 7 (Mutable_ref.get r)

let test_mutable_ref_update () =
  let r = Mutable_ref.make 1 in
  Mutable_ref.update r (fun x -> x + 2);
  Alcotest.(check int) "update applies function" 3 (Mutable_ref.get r)

let test_mutable_ref_update_and_get () =
  let r = Mutable_ref.make 5 in
  let v = Mutable_ref.update_and_get r (fun x -> x * 2) in
  Alcotest.(check int) "update_and_get returns new" 10 v;
  Alcotest.(check int) "update_and_get stores new" 10 (Mutable_ref.get r)

let test_mutable_ref_get_and_set () =
  let r = Mutable_ref.make 3 in
  let old = Mutable_ref.get_and_set r 9 in
  Alcotest.(check int) "get_and_set returns old" 3 old;
  Alcotest.(check int) "get_and_set stores new" 9 (Mutable_ref.get r)

let test_mutable_ref_compare_and_set () =
  let r = Mutable_ref.make "a" in
  let expected = Mutable_ref.get r in
  let ok = Mutable_ref.compare_and_set r expected "b" in
  Alcotest.(check bool) "cas succeeds when expected matches" true ok;
  Alcotest.(check string) "cas stores desired" "b" (Mutable_ref.get r);
  let failed = Mutable_ref.compare_and_set r "a" "c" in
  Alcotest.(check bool) "cas fails when expected mismatches" false failed;
  Alcotest.(check string) "cas leaves value on failure" "b" (Mutable_ref.get r)

let test_mutable_ref_concurrent_update () =
  Eio_main.run @@ fun _stdenv ->
  Eio.Switch.run @@ fun sw ->
  let r = Mutable_ref.make 0 in
  let updates = 10_000 in
  let worker () =
    for _ = 1 to updates do
      Mutable_ref.update r (fun x -> x + 1)
    done
  in
  let left = Eio.Fiber.fork_promise ~sw worker in
  let right = Eio.Fiber.fork_promise ~sw worker in
  Eio.Promise.await_exn left;
  Eio.Promise.await_exn right;
  Alcotest.(check int) "concurrent updates converge" (2 * updates)
    (Mutable_ref.get r)

let test_mutable_ref_incr_decr () =
  let r = Mutable_ref.make 0 in
  Mutable_ref.incr r;
  Alcotest.(check int) "incr" 1 (Mutable_ref.get r);
  Mutable_ref.decr r;
  Alcotest.(check int) "decr" 0 (Mutable_ref.get r);
  Mutable_ref.decr r;
  Alcotest.(check int) "decr again" (-1) (Mutable_ref.get r)


