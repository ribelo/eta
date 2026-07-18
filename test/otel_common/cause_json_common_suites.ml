open Eta

(* Snapshot corpus for Eta_otel.Cause_json: exact JSON strings are locked, so
   encoder drift fails this suite. Interrupt ids are abstract; expectations
   containing ids are assembled from interrupt_id_to_int. *)

type err = [ `A | `B ]

let err_to_yojson = function
  | `A -> `String "A"
  | `B -> `String "B"

let die_record exn =
  match Cause.die exn with Cause.Die die -> die | _ -> assert false

let check name cause expected =
  Alcotest.(check string) name expected
    (Eta_otel.Cause_json.to_string err_to_yojson cause)

let test_fail_leaf () =
  check "fail leaf"
    (Cause.to_portable Fun.id (Cause.fail `A))
    {|{"kind":"fail","error":"A"}|}

let test_die_with_metadata () =
  let die : Cause.Portable.die =
    {
      Cause.Portable.kind = "Failure";
      message = "Failure(\"boom\")";
      backtrace = Some "bt-line-1\nbt-line-2";
      span_name = Some "db.query";
      annotations = [ ("q", "select 1") ];
    }
  in
  check "die with metadata" (Cause.Portable.Die die)
    {|{"kind":"die","exn":"Failure","message":"Failure(\"boom\")","backtrace":"bt-line-1\nbt-line-2","span":"db.query","annotations":[["q","select 1"]]}|}

let test_interrupts () =
  let id = Cause.fresh_interrupt_id () in
  check "anonymous interrupt"
    (Cause.to_portable Fun.id Cause.interrupt)
    {|{"kind":"interrupt","id":null}|};
  check "identified interrupt"
    (Cause.to_portable Fun.id (Cause.interrupt_with_id id))
    (Printf.sprintf {|{"kind":"interrupt","id":%d}|}
       (Cause.interrupt_id_to_int id))

let test_composites () =
  check "sequential and concurrent nest"
    (Cause.to_portable Fun.id
       (Cause.sequential
          [
            Cause.concurrent [ Cause.fail `A; Cause.fail `B ];
            Cause.die (Failure "boom");
          ]))
    {|{"kind":"sequential","causes":[{"kind":"concurrent","causes":[{"kind":"fail","error":"A"},{"kind":"fail","error":"B"}]},{"kind":"die","exn":"Failure","message":"Failure(\"boom\")"}]}|}

let test_finalizer_and_suppressed () =
  let finalizer_die = die_record (Invalid_argument "cleanup") in
  check "finalizer wraps diagnostics"
    (Cause.to_portable Fun.id
       (Cause.finalizer
          (Cause.Finalizer.Sequential
             [ Cause.Finalizer.Fail "cleanup failed"; Cause.Finalizer.Interrupt None ])))
    {|{"kind":"finalizer","cause":{"kind":"sequential","causes":[{"kind":"fail","message":"cleanup failed"},{"kind":"interrupt","id":null}]}}|};
  check "suppressed keeps primary and finalizer"
    (Cause.to_portable Fun.id
       (Cause.suppressed ~primary:(Cause.fail `B)
          ~finalizer:(Cause.Finalizer.Die finalizer_die)))
    {|{"kind":"suppressed","primary":{"kind":"fail","error":"B"},"finalizer":{"kind":"die","exn":"Invalid_argument","message":"Invalid_argument(\"cleanup\")"}}|}

let suite =
  ( "Cause_json",
    [
      Alcotest.test_case "fail leaf" `Quick test_fail_leaf;
      Alcotest.test_case "die with metadata" `Quick test_die_with_metadata;
      Alcotest.test_case "interrupts" `Quick test_interrupts;
      Alcotest.test_case "composites" `Quick test_composites;
      Alcotest.test_case "finalizer and suppressed" `Quick
        test_finalizer_and_suppressed;
    ] )
